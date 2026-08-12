import Foundation

nonisolated struct ServerMutationTransactionPlan: Codable, Equatable, Identifiable, Sendable {
    enum CredentialAction: Codable, Equatable, Sendable {
        case replace(
            transactionID: UUID,
            previousServer: Server?,
            server: Server
        )
        case delete(Server)
    }

    let id: UUID
    let previousServers: [Server]
    let previousWorkspaces: [Workspace]
    let resultingServers: [Server]
    let resultingWorkspaces: [Workspace]
    let pendingMutation: ServerPendingMutation
    let credentialAction: CredentialAction

    var presentsResultingStateAfterMaterialization: Bool {
        if case .delete = credentialAction {
            return true
        }
        return false
    }
}

nonisolated struct ServerMutationTransactionJournal: Codable, Equatable, Sendable {
    enum FailureStage: String, Codable, Equatable, Sendable {
        case credentialPreparation
        case localPersistence
        case pendingSyncQueue
        case credentialFinalization
        case credentialStagingCleanup
    }

    struct Failure: Codable, Equatable, Sendable {
        let stage: FailureStage
        let message: String
    }

    enum Phase: Equatable, Sendable {
        case preparingCredentials
        case materializing
        case enqueueing
        case finalizingCredentials
        case cleaningCredentialStaging
        case finalizing
        case complete
    }

    let plan: ServerMutationTransactionPlan
    var didPrepareCredentials: Bool
    var didMaterializeLocalState = false
    var didEnqueuePendingMutation = false
    var didFinalizeCredentials = false
    var didCleanCredentialStaging: Bool
    var didFinalize = false
    var lastFailure: Failure?

    init(plan: ServerMutationTransactionPlan) {
        self.plan = plan
        switch plan.credentialAction {
        case .replace:
            didPrepareCredentials = false
            didCleanCredentialStaging = false
        case .delete:
            didPrepareCredentials = true
            didCleanCredentialStaging = true
        }
    }

    var phase: Phase {
        if !didPrepareCredentials { return .preparingCredentials }
        if !didMaterializeLocalState { return .materializing }
        if !didEnqueuePendingMutation { return .enqueueing }
        if !didFinalizeCredentials { return .finalizingCredentials }
        if !didCleanCredentialStaging { return .cleaningCredentialStaging }
        return didFinalize ? .complete : .finalizing
    }

    var presentsResultingState: Bool {
        if plan.presentsResultingStateAfterMaterialization {
            return didMaterializeLocalState && didEnqueuePendingMutation
        }
        return didFinalizeCredentials
    }
}

@MainActor
protocol ServerMutationTransactionJournalStoring {
    func loadServerMutationTransactionJournal() throws -> ServerMutationTransactionJournal?
    func storeServerMutationTransactionJournal(_ journal: ServerMutationTransactionJournal) throws
    func materializeServerMutation(_ plan: ServerMutationTransactionPlan) throws
    func clearServerMutationTransactionJournal() throws
}

@MainActor
protocol ServerMutationTransactionEnqueuing {
    func enqueueServerMutation(_ mutation: ServerPendingMutation) throws
}

@MainActor
protocol ServerMutationCredentialTransacting {
    func prepareServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server,
        credentials: ServerCredentials
    ) throws
    func commitServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server
    ) throws
    func discardServerCredentialTransaction(id: UUID) throws
    func cleanupCredentials(for server: Server) throws
}

@MainActor
struct ServerMutationTransaction {
    private let store: any ServerMutationTransactionJournalStoring
    private let mutationQueue: any ServerMutationTransactionEnqueuing
    private let credentials: any ServerMutationCredentialTransacting

    init(
        store: any ServerMutationTransactionJournalStoring,
        mutationQueue: any ServerMutationTransactionEnqueuing,
        credentials: any ServerMutationCredentialTransacting
    ) {
        self.store = store
        self.mutationQueue = mutationQueue
        self.credentials = credentials
    }

    func commitSave(
        _ plan: ServerMutationTransactionPlan,
        credentials newCredentials: ServerCredentials
    ) throws -> ServerMutationTransactionJournal {
        guard try store.loadServerMutationTransactionJournal() == nil else {
            throw ServerMutationTransactionError.recoveryPending
        }
        guard case .replace(let transactionID, let previousServer, let server) = plan.credentialAction else {
            preconditionFailure("A server save transaction requires replacement credentials")
        }

        var journal = ServerMutationTransactionJournal(plan: plan)
        try store.storeServerMutationTransactionJournal(journal)

        do {
            try credentials.prepareServerCredentialTransaction(
                id: transactionID,
                previousServer: previousServer,
                server: server,
                credentials: newCredentials
            )
            journal.didPrepareCredentials = true
            journal.lastFailure = nil
            try store.storeServerMutationTransactionJournal(journal)
        } catch {
            try? credentials.discardServerCredentialTransaction(id: transactionID)
            try? store.clearServerMutationTransactionJournal()
            throw error
        }

        return resume(journal)
    }

    func commitDeletion(
        _ plan: ServerMutationTransactionPlan
    ) throws -> ServerMutationTransactionJournal {
        guard try store.loadServerMutationTransactionJournal() == nil else {
            throw ServerMutationTransactionError.recoveryPending
        }
        guard case .delete = plan.credentialAction else {
            preconditionFailure("A server deletion transaction requires credential cleanup")
        }
        let journal = ServerMutationTransactionJournal(plan: plan)
        try store.storeServerMutationTransactionJournal(journal)
        return resume(journal)
    }

    func resumePending() throws -> ServerMutationTransactionJournal? {
        guard let journal = try store.loadServerMutationTransactionJournal() else {
            return nil
        }

        if !journal.didPrepareCredentials {
            if case .replace(let transactionID, _, _) = journal.plan.credentialAction {
                try credentials.discardServerCredentialTransaction(id: transactionID)
            }
            try store.clearServerMutationTransactionJournal()
            return nil
        }

        return resume(journal)
    }

    private func resume(
        _ storedJournal: ServerMutationTransactionJournal
    ) -> ServerMutationTransactionJournal {
        var journal = storedJournal

        if !journal.didMaterializeLocalState {
            do {
                try store.materializeServerMutation(journal.plan)
                journal.didMaterializeLocalState = true
                journal.lastFailure = nil
                try store.storeServerMutationTransactionJournal(journal)
            } catch {
                return recording(error, at: .localPersistence, in: journal)
            }
        }

        if !journal.didEnqueuePendingMutation {
            do {
                try mutationQueue.enqueueServerMutation(journal.plan.pendingMutation)
                journal.didEnqueuePendingMutation = true
                journal.lastFailure = nil
                try store.storeServerMutationTransactionJournal(journal)
            } catch {
                return recording(error, at: .pendingSyncQueue, in: journal)
            }
        }

        if !journal.didFinalizeCredentials {
            do {
                switch journal.plan.credentialAction {
                case .replace(let transactionID, let previousServer, let server):
                    try credentials.commitServerCredentialTransaction(
                        id: transactionID,
                        previousServer: previousServer,
                        server: server
                    )
                case .delete(let server):
                    try credentials.cleanupCredentials(for: server)
                }
                journal.didFinalizeCredentials = true
                journal.lastFailure = nil
                try store.storeServerMutationTransactionJournal(journal)
            } catch {
                return recording(error, at: .credentialFinalization, in: journal)
            }
        }

        if !journal.didCleanCredentialStaging,
           case .replace(let transactionID, _, _) = journal.plan.credentialAction {
            do {
                try credentials.discardServerCredentialTransaction(id: transactionID)
                journal.didCleanCredentialStaging = true
                journal.lastFailure = nil
                try store.storeServerMutationTransactionJournal(journal)
            } catch {
                return recording(error, at: .credentialStagingCleanup, in: journal)
            }
        }

        if !journal.didFinalize {
            do {
                try store.clearServerMutationTransactionJournal()
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
        at stage: ServerMutationTransactionJournal.FailureStage,
        in journal: ServerMutationTransactionJournal
    ) -> ServerMutationTransactionJournal {
        var failed = journal
        failed.lastFailure = ServerMutationTransactionJournal.Failure(
            stage: stage,
            message: error.localizedDescription
        )
        try? store.storeServerMutationTransactionJournal(failed)
        return failed
    }
}

nonisolated enum ServerMutationTransactionError: LocalizedError, Equatable, Sendable {
    case recoveryPending

    var errorDescription: String? {
        "A previous server change still needs recovery before another change can start."
    }
}
