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
    var journal: WorkspaceDeletionJournal?

    init(servers: [Server], workspaces: [Workspace]) {
        self.servers = servers
        self.workspaces = workspaces
    }

    func loadSnapshot() -> ServerLocalRepositorySnapshot {
        ServerLocalRepositorySnapshot(
            servers: .loaded(servers),
            workspaces: .loaded(workspaces)
        )
    }

    func persist(servers: [Server], workspaces: [Workspace]) throws {
        if let persistError { throw persistError }
        self.servers = servers
        self.workspaces = workspaces
    }

    func clearServerData() {
        servers = []
        workspaces = []
    }

    func loadWorkspaceDeletionJournal() throws -> WorkspaceDeletionJournal? { journal }
    func storeWorkspaceDeletionJournal(_ journal: WorkspaceDeletionJournal) throws {
        self.journal = journal
    }
    func materializeWorkspaceDeletion(_ plan: WorkspaceDeletionPlan) throws {
        servers = plan.remainingServers
        workspaces = plan.remainingWorkspaces
    }
    func clearWorkspaceDeletionJournal() throws { journal = nil }
}

@MainActor
final class ServerRemoteRepositoryFake: ServerRemoteRepository {
    var isAvailable: Bool
    var fetchHandler: (@MainActor (Bool, Int) async throws -> ServerRemoteChanges)?
    var saveServerHandler: (@MainActor (Server) async throws -> Void)?
    var saveWorkspaceHandler: (@MainActor (Workspace) async throws -> Void)?
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
    private(set) var drainCount = 0
    private(set) var completedDrainCount = 0
    var drainHandler: (@MainActor () async -> Void)?
    var enqueueError: Error?

    func pendingServerMutations() -> [ServerPendingMutation] { [] }
    func clearPendingServerAndWorkspaceMutations() {}
    func removePendingServerMutation(_ mutationID: UUID) {}
    func enqueueServerUpsert(_ server: Server) throws {
        if let enqueueError { throw enqueueError }
        enqueuedServerUpserts.append(server)
    }
    func enqueueServerDelete(_ server: Server) throws {
        if let enqueueError { throw enqueueError }
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

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
        storedServers.append(server)
        storedPasswords.append(credentials.password)
        values[server.id] = credentials
    }

    func getCredentials(for server: Server) throws -> ServerCredentials {
        values[server.id] ?? ServerCredentials(serverId: server.id)
    }

    func deleteCredentials(for serverId: UUID) throws {
        deletedServerIDs.append(serverId)
        values[serverId] = nil
    }

    func cleanupCredentials(for server: Server) throws {
        try deleteCredentials(for: server.id)
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

