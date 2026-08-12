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
