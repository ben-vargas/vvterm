import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ServerManagerDetectedSystemTests {
    @Test
    func liveDetectionUpdatesOnlyIdentityAndQueuesSync() async throws {
        let workspace = makeWorkspace()
        let model = try #require(
            AppleHardwareModelIdentifier(rawValue: "MacBookPro18,3")
        )
        let identity = RemoteSystemIdentity(
            kind: .macOS,
            displayName: "macOS",
            appleHardwareModelIdentifier: model
        )
        let server = makeServer(
            workspaceID: workspace.id,
            iconSelection: .custom(.database)
        )
        let local = ServerLocalRepositoryFake(
            servers: [server],
            workspaces: [workspace]
        )
        let credentials = ServerManagerCredentialRepositoryFake()
        var storedCredentials = ServerCredentials(serverId: server.id)
        storedCredentials.password = "unchanged"
        credentials.values[server.id] = storedCredentials
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            credentials: credentials,
            sync: sync
        )

        await manager.publishDetectedSystemIdentity(identity, detectedFor: server)

        let saved = try #require(manager.servers.first)
        #expect(saved.detectedSystemIdentity == identity)
        #expect(saved.iconSelection == .custom(.database))
        #expect(local.servers.first?.detectedSystemIdentity == identity)
        #expect(credentials.values[server.id]?.password == "unchanged")
        #expect(sync.enqueuedServerMutations.count == 1)
        guard case .serverUpsert(let queued) = sync.enqueuedServerMutations[0].payload else {
            Issue.record("Expected a server upsert")
            return
        }
        #expect(queued.detectedSystemIdentity == identity)
        #expect(queued.iconSelection == .custom(.database))
    }

    @Test
    func liveDetectionRejectsChangedEndpointAsStale() async {
        let workspace = makeWorkspace()
        let connectedServer = makeServer(workspaceID: workspace.id, host: "old.example.test")
        let storedServer = makeServer(workspaceID: workspace.id, host: "new.example.test")
        let local = ServerLocalRepositoryFake(
            servers: [storedServer],
            workspaces: [workspace]
        )
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            credentials: ServerManagerCredentialRepositoryFake(),
            sync: sync
        )

        await manager.publishDetectedSystemIdentity(
            RemoteSystemIdentity(kind: .ubuntu, displayName: "Ubuntu"),
            detectedFor: connectedServer
        )

        #expect(manager.servers.first?.detectedSystemIdentity == nil)
        #expect(local.servers.first?.detectedSystemIdentity == nil)
        #expect(sync.enqueuedServerMutations.isEmpty)
    }

    @Test
    func liveDetectionDoesNotWaitForRemoteSync() async throws {
        let workspace = makeWorkspace()
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(
            servers: [server],
            workspaces: [workspace]
        )
        let drainGate = ServerCancellationIgnoringGate<Void>()
        let sync = ServerSyncRepositoryFake()
        sync.drainHandler = { await drainGate.wait() }
        let manager = makeManager(
            local: local,
            credentials: ServerManagerCredentialRepositoryFake(),
            sync: sync,
            isSyncEnabled: { true }
        )
        let identity = RemoteSystemIdentity(kind: .debian, displayName: "Debian")

        await manager.publishDetectedSystemIdentity(identity, detectedFor: server)

        #expect(manager.servers.first?.detectedSystemIdentity == identity)
        #expect(await drainGate.waitUntilStarted())
        drainGate.resolve(())
    }

    private func makeManager(
        local: ServerLocalRepositoryFake,
        credentials: ServerManagerCredentialRepositoryFake,
        sync: ServerSyncRepositoryFake,
        isSyncEnabled: @escaping () -> Bool = { false }
    ) -> ServerManager {
        let now = { Date(timeIntervalSinceReferenceDate: 10_000) }
        let stateStore = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: local,
                preferences: ServerManagerPreferencesFake(),
                freePlanTracker: FreePlanAssignmentTrackerFake(),
                isSyncEnabled: isSyncEnabled,
                now: now,
                makeID: UUID.init,
                defaultWorkspaceName: { "My Servers" }
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
                didDeleteServerLocalData: { _ in },
                isRemoteSchemaError: { _ in false },
                now: now,
                makeID: UUID.init
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

    private func makeServer(
        workspaceID: UUID,
        host: String = "server.example.test",
        iconSelection: ServerIconSelection = .automatic
    ) -> Server {
        Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceId: workspaceID,
            name: "Server",
            host: host,
            username: "root",
            iconSelection: iconSelection,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}
