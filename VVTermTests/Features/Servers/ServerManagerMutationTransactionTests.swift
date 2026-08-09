import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ServerManagerMutationTransactionTests {
    @Test
    func createMetadataPersistenceFailureRollsBackCredentialsAndVisibleState() async {
        let workspace = makeWorkspace()
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        local.persistError = TestTransactionError.persistence
        let credentials = ServerManagerCredentialRepositoryFake()
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(local: local, credentials: credentials, sync: sync)
        let useCase = ServerSaveUseCase(mutations: manager, credentials: credentials)
        let server = makeServer(workspaceID: workspace.id)

        await #expect(throws: TestTransactionError.self) {
            try await useCase.execute(
                .create(server),
                credentials: ServerCredentials(serverId: server.id),
                hasProAccess: true
            )
        }

        #expect(manager.stateStore.servers.isEmpty)
        #expect(credentials.deletedServerIDs == [server.id])
        #expect(sync.enqueuedServerUpserts.isEmpty)
    }

    @Test
    func editMetadataPersistenceFailureRestoresOldCredentialsAndServer() async {
        let workspace = makeWorkspace()
        let storedServer = makeServer(workspaceID: workspace.id, host: "old.example.test")
        var editedServer = storedServer
        editedServer.host = "new.example.test"
        let local = ServerLocalRepositoryFake(servers: [storedServer], workspaces: [workspace])
        local.persistError = TestTransactionError.persistence
        let credentials = ServerManagerCredentialRepositoryFake()
        var previousCredentials = ServerCredentials(serverId: storedServer.id)
        previousCredentials.password = "old-password"
        credentials.values[storedServer.id] = previousCredentials
        let manager = makeManager(local: local, credentials: credentials)
        let useCase = ServerSaveUseCase(mutations: manager, credentials: credentials)
        var editedCredentials = ServerCredentials(serverId: editedServer.id)
        editedCredentials.password = "new-password"

        await #expect(throws: TestTransactionError.self) {
            try await useCase.execute(
                .update(editedServer),
                credentials: editedCredentials,
                hasProAccess: true
            )
        }

        #expect(manager.stateStore.servers == [storedServer])
        #expect(credentials.storedServers == [editedServer, storedServer])
        #expect(credentials.storedPasswords == ["new-password", "old-password"])
        #expect(credentials.deletedServerIDs == [storedServer.id])
    }

    private func makeManager(
        local: ServerLocalRepositoryFake,
        credentials: ServerManagerCredentialRepositoryFake,
        sync: ServerSyncRepositoryFake? = nil
    ) -> ServerManager {
        let sync = sync ?? ServerSyncRepositoryFake()
        let now = { Date(timeIntervalSinceReferenceDate: 10_000) }
        let makeID = { UUID(uuidString: "90000000-0000-0000-0000-000000000001")! }
        let stateStore = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: local,
                preferences: ServerManagerPreferencesFake(),
                freePlanTracker: FreePlanAssignmentTrackerFake(),
                isSyncEnabled: { false },
                now: now,
                makeID: makeID,
                defaultWorkspaceName: { "My Servers" },
                canonicalDefaultWorkspaceNames: { ["My Servers"] }
            )
        )
        return ServerManager(
            dependencies: ServerManagerDependencies(
                stateStore: stateStore,
                remoteRepository: ServerRemoteRepositoryFake(),
                syncRepository: sync,
                credentialRepository: credentials,
                actionAuthorizer: ProtectedServerActionAuthorizerFake(),
                knownHosts: ServerKnownHostRepositoryFake(),
                isRemoteSchemaError: { _ in false },
                now: now,
                makeID: makeID
            ),
            startsAutomatically: false
        )
    }

    private func makeWorkspace() -> Workspace {
        Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Workspace",
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeServer(workspaceID: UUID, host: String = "server.example.test") -> Server {
        Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceId: workspaceID,
            name: "Server",
            host: host,
            username: "root",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}

@MainActor
private final class ServerLocalRepositoryFake: ServerLocalRepository {
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
private final class ServerRemoteRepositoryFake: ServerRemoteRepository {
    let isAvailable = false

    func fetchServerChanges(forceFullFetch: Bool) async throws -> ServerRemoteChanges {
        ServerRemoteChanges(
            servers: [],
            workspaces: [],
            deletedServerIDs: [],
            deletedWorkspaceIDs: [],
            isFullFetch: forceFullFetch
        )
    }

    func saveServer(_ server: Server) async throws {}
    func saveWorkspace(_ workspace: Workspace) async throws {}
}

@MainActor
private final class ServerSyncRepositoryFake: ServerSyncRepository {
    var enqueuedServerUpserts: [Server] = []

    func pendingServerMutations() -> [ServerPendingMutation] { [] }
    func clearPendingServerAndWorkspaceMutations() {}
    func removePendingServerMutation(_ mutationID: UUID) {}
    func enqueueServerUpsert(_ server: Server) { enqueuedServerUpserts.append(server) }
    func enqueueServerDelete(_ server: Server) {}
    func enqueueWorkspaceUpsert(_ workspace: Workspace) {}
    func enqueueWorkspaceDelete(_ workspace: Workspace) {}
    func drainPendingMutations() async {}
    func enqueueWorkspaceDeletionMutations(_ mutations: [ServerPendingMutation]) throws {}
}

@MainActor
private final class ServerManagerCredentialRepositoryFake:
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
private final class ProtectedServerActionAuthorizerFake: ProtectedServerActionAuthorizing {
    func authorize(
        _ server: Server,
        for action: ServerProtectedAction
    ) async -> Bool {
        true
    }
}

@MainActor
private final class ServerKnownHostRepositoryFake: ServerKnownHostRepository {
    func remove(host: String, port: Int) {}
}

@MainActor
private final class FreePlanAssignmentTrackerFake: FreePlanAssignmentTracking {
    func trackFreePlanGenerationAssigned(
        generation: String,
        serverCount: Int,
        reason: String
    ) {}
}

@MainActor
private final class ServerManagerPreferencesFake: ServerManagerPreferences {
    var didBootstrapDefaultWorkspace = true
    var hasSeenWelcome = true
    var freePlanGeneration: FreePlanGeneration? = .currentOneServer
    var pendingBootstrapWorkspaceID: UUID?
}

private enum TestTransactionError: Error {
    case persistence
}
