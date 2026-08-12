import Foundation
import Testing
@testable import VVTerm


@MainActor
final class ServerCancellationIgnoringGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private(set) var isStarted = false
    private(set) var cancellationCount = 0

    func wait() async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isStarted = true
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancellationCount += 1
            }
        }
    }

    func resolve(_ value: Value) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<2_000 {
            if isStarted { return true }
            await Task.yield()
        }
        return isStarted
    }

    func waitUntilCancelled() async -> Bool {
        for _ in 0..<2_000 {
            if cancellationCount > 0 { return true }
            await Task.yield()
        }
        return cancellationCount > 0
    }
}

@MainActor
final class ServerLocalRepositoryFake: ServerLocalRepository {
    var servers: [Server]
    var workspaces: [Workspace]
    var persistError: Error?
    var serverMutationJournalStoreError: Error?
    var serverMutationJournalClearError: Error?
    var serverMutationJournal: ServerMutationTransactionJournal?
    var journal: WorkspaceDeletionJournal?
    var environmentDeletionJournal: EnvironmentDeletionJournal?
    var ambiguousCloudRecoveryBackup: AmbiguousCloudRecoveryBackup?

    init(servers: [Server], workspaces: [Workspace]) {
        self.servers = servers
        self.workspaces = workspaces
    }

    func loadSnapshot() -> ServerLocalRepositorySnapshot {
        if let journal = serverMutationJournal {
            return ServerLocalRepositorySnapshot(
                servers: .loaded(
                    journal.presentsResultingState
                        ? journal.plan.resultingServers
                        : journal.plan.previousServers
                ),
                workspaces: .loaded(
                    journal.presentsResultingState
                        ? journal.plan.resultingWorkspaces
                        : journal.plan.previousWorkspaces
                )
            )
        }
        return ServerLocalRepositorySnapshot(
            servers: .loaded(servers),
            workspaces: .loaded(workspaces)
        )
    }

    func persist(servers: [Server], workspaces: [Workspace]) throws {
        if serverMutationJournal != nil { throw ServerLocalStoreError.serverMutationPending }
        if let persistError { throw persistError }
        self.servers = servers
        self.workspaces = workspaces
    }

    func clearServerData() throws {
        if serverMutationJournal != nil { throw ServerLocalStoreError.serverMutationPending }
        servers = []
        workspaces = []
    }

    func loadAmbiguousCloudRecoveryBackup() throws -> AmbiguousCloudRecoveryBackup? {
        ambiguousCloudRecoveryBackup
    }
    func storeAmbiguousCloudRecoveryBackup(_ backup: AmbiguousCloudRecoveryBackup) throws {
        if ambiguousCloudRecoveryBackup == nil {
            ambiguousCloudRecoveryBackup = backup
        }
    }
    func clearAmbiguousCloudRecoveryBackup() throws {
        ambiguousCloudRecoveryBackup = nil
    }

    func loadServerMutationTransactionJournal() throws -> ServerMutationTransactionJournal? {
        serverMutationJournal
    }
    func storeServerMutationTransactionJournal(
        _ journal: ServerMutationTransactionJournal
    ) throws {
        if let serverMutationJournalStoreError { throw serverMutationJournalStoreError }
        serverMutationJournal = journal
    }
    func materializeServerMutation(_ plan: ServerMutationTransactionPlan) throws {
        if let persistError { throw persistError }
        servers = plan.resultingServers
        workspaces = plan.resultingWorkspaces
    }
    func clearServerMutationTransactionJournal() throws {
        if let serverMutationJournalClearError { throw serverMutationJournalClearError }
        serverMutationJournal = nil
    }

    func loadWorkspaceDeletionJournal() throws -> WorkspaceDeletionJournal? { journal }
    func storeWorkspaceDeletionJournal(_ journal: WorkspaceDeletionJournal) throws {
        if serverMutationJournal != nil { throw ServerLocalStoreError.serverMutationPending }
        self.journal = journal
    }
    func materializeWorkspaceDeletion(_ plan: WorkspaceDeletionPlan) throws {
        servers = plan.remainingServers
        workspaces = plan.remainingWorkspaces
    }
    func clearWorkspaceDeletionJournal() throws { journal = nil }
    func loadEnvironmentDeletionJournal() throws -> EnvironmentDeletionJournal? { environmentDeletionJournal }
    func storeEnvironmentDeletionJournal(_ journal: EnvironmentDeletionJournal) throws {
        if serverMutationJournal != nil { throw ServerLocalStoreError.serverMutationPending }
        environmentDeletionJournal = journal
    }
    func materializeEnvironmentDeletion(_ plan: EnvironmentDeletionPlan) throws {
        if let persistError { throw persistError }
        servers = plan.resultingServers
        workspaces = plan.resultingWorkspaces
    }
    func clearEnvironmentDeletionJournal() throws { environmentDeletionJournal = nil }
}

@MainActor
final class ServerRemoteRepositoryFake: ServerRemoteRepository {
    var isAvailable: Bool
    var fetchHandler: (@MainActor (Bool, Int) async throws -> ServerRemoteChanges)?
    var saveServerHandler: (@MainActor (Server) async throws -> Void)?
    var saveWorkspaceHandler: (@MainActor (Workspace) async throws -> Void)?
    var acceptError: Error?
    private(set) var fetchCount = 0
    private(set) var fetchForceFullModes: [Bool] = []
    private(set) var savedServers: [Server] = []
    private(set) var savedWorkspaces: [Workspace] = []
    private(set) var acceptedCheckpoints: [ServerRemoteChangeCheckpoint] = []

    init(isAvailable: Bool = false) {
        self.isAvailable = isAvailable
    }

    func fetchServerChanges(forceFullFetch: Bool) async throws -> ServerRemoteChanges {
        fetchCount += 1
        fetchForceFullModes.append(forceFullFetch)
        if let fetchHandler {
            return try await fetchHandler(forceFullFetch, fetchCount)
        }
        return ServerRemoteChanges(
            servers: [],
            workspaces: [],
            deletedServerIDs: [],
            deletedWorkspaceIDs: [],
            isFullFetch: forceFullFetch,
            checkpoint: ServerRemoteChangeCheckpoint(
                id: UUID(uuidString: "80000000-0000-0000-0000-000000000005")!
            )
        )
    }

    func acceptServerChanges(_ checkpoint: ServerRemoteChangeCheckpoint) throws {
        if let acceptError { throw acceptError }
        acceptedCheckpoints.append(checkpoint)
    }

    func saveServer(_ server: Server) async throws {
        savedServers.append(server)
        try await saveServerHandler?(server)
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        savedWorkspaces.append(workspace)
        try await saveWorkspaceHandler?(workspace)
    }
}

@MainActor
final class ServerSyncRepositoryFake: ServerSyncRepository {
    var enqueuedServerUpserts: [Server] = []
    var enqueuedServerMutations: [ServerPendingMutation] = []
    private(set) var drainCount = 0
    private(set) var completedDrainCount = 0
    var drainHandler: (@MainActor () async -> Void)?
    var enqueueError: Error?
    var clearError: Error?
    private(set) var clearCount = 0
    var environmentDeletionMutations: [ServerPendingMutation] = []

    func pendingServerMutations() -> [ServerPendingMutation] { enqueuedServerMutations }
    func clearPendingServerAndWorkspaceMutations() throws {
        clearCount += 1
        if let clearError { throw clearError }
        enqueuedServerMutations.removeAll()
    }
    func removePendingServerMutation(_ mutationID: UUID) {}
    func enqueueServerUpsert(_ server: Server) throws {
        if let enqueueError { throw enqueueError }
        enqueuedServerUpserts.append(server)
    }
    func enqueueServerDelete(_ server: Server) throws {
        if let enqueueError { throw enqueueError }
    }
    func enqueueServerMutation(_ mutation: ServerPendingMutation) throws {
        if let enqueueError { throw enqueueError }
        enqueuedServerMutations.removeAll {
            $0.payload.coalescingIdentity == mutation.payload.coalescingIdentity
        }
        enqueuedServerMutations.append(mutation)
    }
    func enqueueWorkspaceUpsert(_ workspace: Workspace) throws {
        if let enqueueError { throw enqueueError }
    }
    func enqueueWorkspaceDelete(_ workspace: Workspace) throws {
        if let enqueueError { throw enqueueError }
    }
    func drainPendingMutations() async {
        drainCount += 1
        await drainHandler?()
        completedDrainCount += 1
    }
    func enqueueWorkspaceDeletionMutations(_ mutations: [ServerPendingMutation]) throws {}
    func enqueueEnvironmentDeletionMutations(_ mutations: [ServerPendingMutation]) throws {
        if let enqueueError { throw enqueueError }
        environmentDeletionMutations = mutations
    }
}

enum ServerSyncRepositoryTestError: Error {
    case rejected
}

@MainActor
final class ServerManagerCredentialRepositoryFake:
    ServerManagerCredentialRepository,
    ServerCredentialTransactionRepository {
    var values: [UUID: ServerCredentials] = [:]
    var storedServers: [Server] = []
    var storedPasswords: [String?] = []
    var deletedServerIDs: [UUID] = []
    var preparedTransactions: [UUID: (Server?, Server, ServerCredentials)] = [:]
    var committedTransactionIDs: [UUID] = []
    var discardedTransactionIDs: [UUID] = []
    var prepareError: Error?
    var commitError: Error?
    var deleteError: Error?

    func prepareServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server,
        credentials: ServerCredentials
    ) throws {
        if let prepareError { throw prepareError }
        preparedTransactions[id] = (previousServer, server, credentials)
    }

    func commitServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server
    ) throws {
        if let commitError { throw commitError }
        guard let prepared = preparedTransactions[id] else {
            throw TestTransactionError.persistence
        }
        committedTransactionIDs.append(id)
        try storeCredentials(prepared.2, for: server)
    }

    func discardServerCredentialTransaction(id: UUID) throws {
        discardedTransactionIDs.append(id)
        preparedTransactions[id] = nil
    }

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
        storedServers.append(server)
        storedPasswords.append(credentials.password)
        values[server.id] = credentials
    }

    func getCredentials(for server: Server) throws -> ServerCredentials {
        values[server.id] ?? ServerCredentials(serverId: server.id)
    }

    func deleteCredentials(for serverId: UUID) throws {
        if let deleteError { throw deleteError }
        deletedServerIDs.append(serverId)
        values[serverId] = nil
    }

    func cleanupCredentials(for server: Server) throws {
        try deleteCredentials(for: server.id)
    }
}

private extension ServerPendingMutation.Payload {
    var coalescingIdentity: String {
        switch self {
        case .serverUpsert(let server), .serverDelete(let server):
            return "server:\(server.id.uuidString)"
        case .workspaceUpsert(let workspace), .workspaceDelete(let workspace):
            return "workspace:\(workspace.id.uuidString)"
        }
    }
}

@MainActor
final class ProtectedServerActionAuthorizerFake: ProtectedServerActionAuthorizing {
    func authorize(
        _ server: Server,
        for action: ServerProtectedAction
    ) async -> Bool {
        true
    }
}

@MainActor
final class ServerKnownHostRepositoryFake: ServerKnownHostRepository {
    func remove(host: String, port: Int) {}
}

@MainActor
final class FreePlanAssignmentTrackerFake: FreePlanAssignmentTracking {
    func trackFreePlanGenerationAssigned(
        generation: String,
        serverCount: Int,
        reason: String
    ) {}
}

@MainActor
final class ServerManagerPreferencesFake: ServerManagerPreferences {
    var didBootstrapDefaultWorkspace = true
    var hasSeenWelcome = true
    var freePlanGeneration: FreePlanGeneration? = .currentOneServer
    var pendingBootstrapWorkspaceID: UUID?
}

enum TestTransactionError: Error {
    case persistence
}

enum ServerRemoteTestError: Error {
    case schema
}
