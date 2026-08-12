import Foundation

nonisolated struct EnvironmentDeletionResult: Equatable, Sendable {
    let workspace: Workspace
    let selectedEnvironment: ServerEnvironment
}

nonisolated struct EnvironmentDeletionPlan: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let environmentID: UUID
    let fallback: ServerEnvironment
    let updatedWorkspace: Workspace
    let updatedServers: [Server]
    let resultingServers: [Server]
    let resultingWorkspaces: [Workspace]
    let pendingMutations: [ServerPendingMutation]

    init(
        workspaceID: UUID,
        environmentID: UUID,
        fallbackID: UUID,
        servers: [Server],
        workspaces: [Workspace],
        id: UUID,
        mutationIDs: [UUID],
        mutationDate: Date
    ) throws {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw VVTermError.workspaceNotFound
        }
        let workspace = workspaces[workspaceIndex]
        guard let environment = workspace.environment(withId: environmentID) else {
            throw VVTermError.environmentNotFound
        }
        guard !environment.isBuiltIn else {
            throw VVTermError.environmentDeletionNotAllowed
        }
        guard fallbackID != environmentID,
              let fallback = workspace.environment(withId: fallbackID) else {
            throw VVTermError.environmentFallbackUnavailable
        }

        let affectedServers = servers.filter {
            $0.workspaceId == workspaceID && $0.environment.id == environmentID
        }
        guard mutationIDs.count == affectedServers.count + 1 else {
            throw VVTermError.environmentDeletionRecoveryPending
        }

        var updatedWorkspace = workspace
        updatedWorkspace.environments.removeAll { $0.id == environmentID }
        if updatedWorkspace.lastSelectedEnvironmentId == environmentID {
            updatedWorkspace.lastSelectedEnvironmentId = fallback.id
        }
        updatedWorkspace.updatedAt = mutationDate

        var updatedServersByID: [UUID: Server] = [:]
        for server in affectedServers {
            var updatedServer = server
            updatedServer.environment = fallback
            updatedServer.updatedAt = mutationDate
            updatedServersByID[server.id] = updatedServer
        }

        var resultingServers = servers
        for index in resultingServers.indices {
            if let updated = updatedServersByID[resultingServers[index].id] {
                resultingServers[index] = updated
            }
        }
        var resultingWorkspaces = workspaces
        resultingWorkspaces[workspaceIndex] = updatedWorkspace

        self.id = id
        self.workspaceID = workspaceID
        self.environmentID = environmentID
        self.fallback = fallback
        self.updatedWorkspace = updatedWorkspace
        self.updatedServers = affectedServers.compactMap { updatedServersByID[$0.id] }
        self.resultingServers = resultingServers
        self.resultingWorkspaces = resultingWorkspaces
        self.pendingMutations = [
            ServerPendingMutation(
                id: mutationIDs[0],
                payload: .workspaceUpsert(updatedWorkspace),
                createdAt: mutationDate
            )
        ] + self.updatedServers.enumerated().map { index, server in
            ServerPendingMutation(
                id: mutationIDs[index + 1],
                payload: .serverUpsert(server),
                createdAt: mutationDate.addingTimeInterval(TimeInterval(index + 1))
            )
        }
    }
}

nonisolated struct EnvironmentDeletionJournal: Codable, Equatable, Sendable {
    enum Phase: Equatable {
        case materializing
        case enqueueing
        case finalizing
        case complete
    }

    let plan: EnvironmentDeletionPlan
    var didMaterializeLocalState = false
    var didEnqueuePendingMutations = false
    var didFinalize = false
    var lastFailureMessage: String?

    var phase: Phase {
        if !didMaterializeLocalState { return .materializing }
        if !didEnqueuePendingMutations { return .enqueueing }
        return didFinalize ? .complete : .finalizing
    }
}

@MainActor
protocol EnvironmentDeletionJournalStoring {
    func loadEnvironmentDeletionJournal() throws -> EnvironmentDeletionJournal?
    func storeEnvironmentDeletionJournal(_ journal: EnvironmentDeletionJournal) throws
    func materializeEnvironmentDeletion(_ plan: EnvironmentDeletionPlan) throws
    func clearEnvironmentDeletionJournal() throws
}

@MainActor
protocol EnvironmentDeletionMutationEnqueuing {
    func enqueueEnvironmentDeletionMutations(_ mutations: [ServerPendingMutation]) throws
}

@MainActor
struct EnvironmentDeletionTransaction {
    private let store: any EnvironmentDeletionJournalStoring
    private let mutationQueue: any EnvironmentDeletionMutationEnqueuing

    init(
        store: any EnvironmentDeletionJournalStoring,
        mutationQueue: any EnvironmentDeletionMutationEnqueuing
    ) {
        self.store = store
        self.mutationQueue = mutationQueue
    }

    func commit(_ plan: EnvironmentDeletionPlan) throws -> EnvironmentDeletionJournal {
        let journal = EnvironmentDeletionJournal(plan: plan)
        try store.storeEnvironmentDeletionJournal(journal)
        return resume(journal)
    }

    func resumePending() throws -> EnvironmentDeletionJournal? {
        guard let journal = try store.loadEnvironmentDeletionJournal() else { return nil }
        return resume(journal)
    }

    private func resume(_ storedJournal: EnvironmentDeletionJournal) -> EnvironmentDeletionJournal {
        var journal = storedJournal

        if !journal.didMaterializeLocalState {
            do {
                try store.materializeEnvironmentDeletion(journal.plan)
                journal.didMaterializeLocalState = true
                journal.lastFailureMessage = nil
                try store.storeEnvironmentDeletionJournal(journal)
            } catch {
                return recording(error, in: journal)
            }
        }

        if !journal.didEnqueuePendingMutations {
            do {
                try mutationQueue.enqueueEnvironmentDeletionMutations(journal.plan.pendingMutations)
                journal.didEnqueuePendingMutations = true
                journal.lastFailureMessage = nil
                try store.storeEnvironmentDeletionJournal(journal)
            } catch {
                return recording(error, in: journal)
            }
        }

        if !journal.didFinalize {
            do {
                try store.clearEnvironmentDeletionJournal()
                journal.didFinalize = true
                journal.lastFailureMessage = nil
            } catch {
                return recording(error, in: journal)
            }
        }
        return journal
    }

    private func recording(_ error: Error, in journal: EnvironmentDeletionJournal) -> EnvironmentDeletionJournal {
        var failed = journal
        failed.lastFailureMessage = error.localizedDescription
        try? store.storeEnvironmentDeletionJournal(failed)
        return failed
    }
}
