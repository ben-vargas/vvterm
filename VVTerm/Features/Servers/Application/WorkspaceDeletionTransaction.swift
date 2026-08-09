import Foundation

struct WorkspaceDeletionPlan: Codable, Equatable, Identifiable {
    let id: UUID
    let workspace: Workspace
    let deletedServers: [Server]
    let remainingServers: [Server]
    let remainingWorkspaces: [Workspace]
    let pendingMutations: [ServerPendingMutation]

    init?(
        workspaceID: UUID,
        servers: [Server],
        workspaces: [Workspace],
        id: UUID,
        mutationIDs: [UUID],
        mutationDate: Date
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }

        let deletedServers = servers.filter { $0.workspaceId == workspaceID }
        guard let workspaceMutationID = mutationIDs.last,
              mutationIDs.dropLast().count == deletedServers.count else {
            return nil
        }
        self.id = id
        self.workspace = workspace
        self.deletedServers = deletedServers
        self.remainingServers = servers.filter { $0.workspaceId != workspaceID }
        self.remainingWorkspaces = workspaces.filter { $0.id != workspaceID }
        self.pendingMutations = deletedServers.enumerated().map { index, server in
            ServerPendingMutation(
                id: mutationIDs[index],
                payload: .serverDelete(server),
                createdAt: mutationDate.addingTimeInterval(TimeInterval(index))
            )
        } + [
            ServerPendingMutation(
                id: workspaceMutationID,
                payload: .workspaceDelete(workspace),
                createdAt: mutationDate.addingTimeInterval(TimeInterval(deletedServers.count))
            )
        ]
    }

    func hasSameDeletionSnapshot(as other: WorkspaceDeletionPlan) -> Bool {
        workspace == other.workspace &&
        deletedServers == other.deletedServers &&
        remainingServers == other.remainingServers &&
        remainingWorkspaces == other.remainingWorkspaces
    }
}

struct WorkspaceDeletionJournal: Codable, Equatable {
    enum FailureStage: String, Codable, Equatable {
        case localPersistence
        case pendingSyncQueue
        case credentialCleanup
    }

    struct Failure: Codable, Equatable {
        let stage: FailureStage
        let message: String
    }

    enum Phase: Equatable {
        case materializing(lastFailure: Failure?)
        case credentialCleanup(pendingServerIDs: [UUID], lastFailure: Failure?)
        case finalizing(lastFailure: Failure?)
        case complete
    }

    let plan: WorkspaceDeletionPlan
    var didMaterializeLocalState: Bool
    var didEnqueuePendingMutations: Bool
    var pendingCredentialServerIDs: [UUID]
    var lastFailure: Failure?
    var didFinalize: Bool

    init(plan: WorkspaceDeletionPlan) {
        self.plan = plan
        self.didMaterializeLocalState = false
        self.didEnqueuePendingMutations = false
        self.pendingCredentialServerIDs = plan.deletedServers.map(\.id)
        self.lastFailure = nil
        self.didFinalize = false
    }

    var phase: Phase {
        if !didMaterializeLocalState || !didEnqueuePendingMutations {
            return .materializing(lastFailure: lastFailure)
        }
        if !pendingCredentialServerIDs.isEmpty {
            return .credentialCleanup(
                pendingServerIDs: pendingCredentialServerIDs,
                lastFailure: lastFailure
            )
        }
        return didFinalize ? .complete : .finalizing(lastFailure: lastFailure)
    }
}

@MainActor
protocol WorkspaceDeletionJournalStoring {
    func loadWorkspaceDeletionJournal() throws -> WorkspaceDeletionJournal?
    func storeWorkspaceDeletionJournal(_ journal: WorkspaceDeletionJournal) throws
    func materializeWorkspaceDeletion(_ plan: WorkspaceDeletionPlan) throws
    func clearWorkspaceDeletionJournal() throws
}

@MainActor
protocol WorkspaceDeletionMutationEnqueuing {
    func enqueueWorkspaceDeletionMutations(_ mutations: [ServerPendingMutation]) throws
}

@MainActor
protocol WorkspaceDeletionCredentialCleaning {
    func cleanupCredentials(for server: Server) throws
}

@MainActor
struct WorkspaceDeletionTransaction {
    private let store: any WorkspaceDeletionJournalStoring
    private let mutationQueue: any WorkspaceDeletionMutationEnqueuing
    private let credentialCleaner: any WorkspaceDeletionCredentialCleaning

    init(
        store: any WorkspaceDeletionJournalStoring,
        mutationQueue: any WorkspaceDeletionMutationEnqueuing,
        credentialCleaner: any WorkspaceDeletionCredentialCleaning
    ) {
        self.store = store
        self.mutationQueue = mutationQueue
        self.credentialCleaner = credentialCleaner
    }

    func commit(_ plan: WorkspaceDeletionPlan) throws -> WorkspaceDeletionJournal {
        let journal = WorkspaceDeletionJournal(plan: plan)
        try store.storeWorkspaceDeletionJournal(journal)
        return resume(journal)
    }

    func resumePending() throws -> WorkspaceDeletionJournal? {
        guard let journal = try store.loadWorkspaceDeletionJournal() else {
            return nil
        }
        return resume(journal)
    }

    private func resume(_ storedJournal: WorkspaceDeletionJournal) -> WorkspaceDeletionJournal {
        var journal = storedJournal

        if !journal.didMaterializeLocalState {
            do {
                try store.materializeWorkspaceDeletion(journal.plan)
                journal.didMaterializeLocalState = true
                journal.lastFailure = nil
                try store.storeWorkspaceDeletionJournal(journal)
            } catch {
                return recording(error, at: .localPersistence, in: journal)
            }
        }

        if !journal.didEnqueuePendingMutations {
            do {
                try mutationQueue.enqueueWorkspaceDeletionMutations(journal.plan.pendingMutations)
                journal.didEnqueuePendingMutations = true
                journal.lastFailure = nil
                try store.storeWorkspaceDeletionJournal(journal)
            } catch {
                return recording(error, at: .pendingSyncQueue, in: journal)
            }
        }

        while let serverID = journal.pendingCredentialServerIDs.first,
              let server = journal.plan.deletedServers.first(where: { $0.id == serverID }) {
            do {
                try credentialCleaner.cleanupCredentials(for: server)
                journal.pendingCredentialServerIDs.removeFirst()
                journal.lastFailure = nil
                try store.storeWorkspaceDeletionJournal(journal)
            } catch {
                return recording(error, at: .credentialCleanup, in: journal)
            }
        }

        if case .finalizing = journal.phase {
            do {
                try store.clearWorkspaceDeletionJournal()
                journal.didFinalize = true
                journal.lastFailure = nil
            } catch {
                return recording(error, at: .localPersistence, in: journal)
            }
        }
        return journal
    }

    private func recording(
        _ error: Error,
        at stage: WorkspaceDeletionJournal.FailureStage,
        in journal: WorkspaceDeletionJournal
    ) -> WorkspaceDeletionJournal {
        var failedJournal = journal
        failedJournal.lastFailure = WorkspaceDeletionJournal.Failure(
            stage: stage,
            message: error.localizedDescription
        )
        try? store.storeWorkspaceDeletionJournal(failedJournal)
        return failedJournal
    }
}

extension CloudKitSyncCoordinator: WorkspaceDeletionMutationEnqueuing {
    func enqueueWorkspaceDeletionMutations(_ mutations: [ServerPendingMutation]) throws {
        guard mutations.allSatisfy(\.payload.isDeletion) else {
            throw WorkspaceDeletionTransactionError.invalidPendingMutation
        }
        try enqueueMutationsAtomically(mutations.map(PendingCloudKitMutation.init))
    }
}

extension KeychainManager: WorkspaceDeletionCredentialCleaning {
    func cleanupCredentials(for server: Server) throws {
        try deleteCredentials(for: server.id)
        guard try credentialBindingStatus(for: server) == .noCredentials else {
            throw WorkspaceDeletionTransactionError.credentialCleanupIncomplete
        }
    }
}

private extension ServerPendingMutation.Payload {
    var isDeletion: Bool {
        switch self {
        case .serverDelete, .workspaceDelete:
            return true
        case .serverUpsert, .workspaceUpsert:
            return false
        }
    }
}

private extension PendingCloudKitMutation {
    init(_ mutation: ServerPendingMutation) {
        let payload: PendingCloudKitMutationPayload
        switch mutation.payload {
        case .serverUpsert(let server):
            payload = .serverUpsert(server)
        case .serverDelete(let server):
            payload = .serverDelete(server)
        case .workspaceUpsert(let workspace):
            payload = .workspaceUpsert(workspace)
        case .workspaceDelete(let workspace):
            payload = .workspaceDelete(workspace)
        }
        self.init(id: mutation.id, payload: payload, createdAt: mutation.createdAt)
    }
}

private enum WorkspaceDeletionTransactionError: LocalizedError {
    case invalidPendingMutation
    case credentialCleanupIncomplete

    var errorDescription: String? {
        switch self {
        case .invalidPendingMutation:
            return "The workspace deletion contains an invalid pending mutation."
        case .credentialCleanupIncomplete:
            return "The server credentials are still present after cleanup."
        }
    }
}
