import Foundation
import Testing
@testable import VVTerm


@Suite(.serialized)
@MainActor
struct ServerManagerLoadLifecycleTests {
    @Test
    func syncDisableCancelsLoadAndRejectsCancellationIgnoringCompletion() async {
        var syncEnabled = true
        let gate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake()
        remote.fetchHandler = { _, _ in await gate.wait() }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            remote: remote,
            sync: sync,
            isSyncEnabled: { syncEnabled }
        )
        let loadTask = Task { await manager.loadData() }

        #expect(await gate.waitUntilStarted())
        syncEnabled = false
        manager.handleSyncDisabled()

        #expect(await gate.waitUntilCancelled())
        let checkpoint = ServerRemoteChangeCheckpoint(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
        )
        gate.resolve(
            makeRemoteChanges(
                workspaceName: "Late Remote",
                checkpoint: checkpoint
            )
        )
        await loadTask.value

        #expect(manager.workspaces.isEmpty)
        #expect(manager.servers.isEmpty)
        #expect(manager.stateStore.loadState.phase == .idle)
        #expect(sync.drainCount == 0)
        #expect(remote.acceptedCheckpoints.isEmpty)
    }

    @Test
    func restartAcceptsCheckpointOnlyAfterRemoteBatchPersists() async {
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        local.persistError = TestTransactionError.persistence
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        let checkpoint = ServerRemoteChangeCheckpoint(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
        )
        let changes = makeRemoteChanges(
            workspaceName: "Durable Remote",
            checkpoint: checkpoint
        )
        remote.fetchHandler = { _, _ in changes }
        let sync = ServerSyncRepositoryFake()
        let firstManager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )

        await firstManager.loadData()

        #expect(remote.acceptedCheckpoints.isEmpty)
        #expect(local.workspaces.isEmpty)
        #expect(firstManager.workspaces.isEmpty)
        #expect(sync.drainCount == 0)

        local.persistError = nil
        let restartedManager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )
        await restartedManager.loadData()

        #expect(remote.fetchCount == 2)
        #expect(remote.acceptedCheckpoints == [checkpoint])
        #expect(local.workspaces.map(\.name) == ["Durable Remote"])
        #expect(sync.drainCount == 1)
    }

    @Test
    func failedFullFetchRestoresBootstrapFetchIdentityUntilCheckpointAcceptance() async {
        let workspace = makeWorkspace(name: "Bootstrap")
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        local.persistError = TestTransactionError.persistence
        let preferences = ServerManagerPreferencesFake()
        preferences.pendingBootstrapWorkspaceID = workspace.id
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        let checkpoint = ServerRemoteChangeCheckpoint(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000006")!
        )
        let changes = ServerRemoteChanges(
            servers: [],
            workspaces: [],
            deletedServerIDs: [],
            deletedWorkspaceIDs: [],
            isFullFetch: true,
            checkpoint: checkpoint
        )
        remote.fetchHandler = { _, _ in changes }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            preferences: preferences,
            isSyncEnabled: { true }
        )

        await manager.loadData()

        #expect(remote.fetchForceFullModes == [true])
        #expect(manager.stateStore.transientBootstrapWorkspaceID == workspace.id)
        #expect(manager.workspaces == [workspace])
        #expect(remote.acceptedCheckpoints.isEmpty)
        #expect(sync.drainCount == 0)

        local.persistError = nil
        await manager.loadData()

        #expect(remote.fetchForceFullModes == [true, true])
        #expect(manager.stateStore.transientBootstrapWorkspaceID == nil)
        #expect(remote.acceptedCheckpoints == [checkpoint])
        #expect(sync.drainCount == 1)
    }

    @Test
    func staleLoadGenerationCannotReplaceNewerLoad() async {
        var syncEnabled = true
        let firstGate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake()
        remote.fetchHandler = { _, fetchCount in
            if fetchCount == 1 {
                return await firstGate.wait()
            }
            return makeRemoteChanges(workspaceName: "Current Remote")
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            remote: remote,
            sync: sync,
            isSyncEnabled: { syncEnabled }
        )
        let staleLoadTask = Task { await manager.loadData() }

        #expect(await firstGate.waitUntilStarted())
        syncEnabled = false
        manager.handleSyncDisabled()
        #expect(await firstGate.waitUntilCancelled())

        syncEnabled = true
        await manager.loadData()
        #expect(manager.workspaces.map(\.name) == ["Current Remote"])

        firstGate.resolve(makeRemoteChanges(workspaceName: "Stale Remote"))
        await staleLoadTask.value

        #expect(manager.workspaces.map(\.name) == ["Current Remote"])
        #expect(sync.drainCount == 1)
    }

    @Test
    func blockedAutomaticLoadDoesNotRetainOwnerAndObservesCancellation() async {
        let gate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake()
        remote.fetchHandler = { _, _ in await gate.wait() }
        var manager: ServerManager? = makeManager(
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true },
            startsAutomatically: true
        )
        weak var releasedManager: ServerManager?
        releasedManager = manager

        #expect(await gate.waitUntilStarted())
        manager = nil

        #expect(await gate.waitUntilCancelled())
        for _ in 0..<2_000 where releasedManager != nil {
            await Task.yield()
        }
        #expect(releasedManager == nil)

        gate.resolve(makeRemoteChanges(workspaceName: "Ignored Remote"))
    }

    @Test
    func blockedAutomaticLoadDoesNotRetainCoordinator() async {
        let gate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake()
        remote.fetchHandler = { _, _ in await gate.wait() }
        var coordinator: ServerRemoteSyncCoordinator? = makeRemoteSyncCoordinator(
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true }
        )
        weak var releasedCoordinator: ServerRemoteSyncCoordinator?
        releasedCoordinator = coordinator
        coordinator?.startAutomaticLoad()

        #expect(await gate.waitUntilStarted())
        coordinator = nil

        #expect(await gate.waitUntilCancelled())
        for _ in 0..<2_000 where releasedCoordinator != nil {
            await Task.yield()
        }
        #expect(releasedCoordinator == nil)

        gate.resolve(makeRemoteChanges(workspaceName: "Ignored Remote"))
    }

    @Test
    func syncDisableCancelsBlockedStartupRecoveryBeforeRemoteLoad() async throws {
        var syncEnabled = true
        let drainGate = ServerCancellationIgnoringGate<Void>()
        let sync = ServerSyncRepositoryFake()
        sync.drainHandler = { await drainGate.wait() }
        let remote = ServerRemoteRepositoryFake()
        let manager = makeManager(
            local: try makePendingDeletionLocal(),
            remote: remote,
            sync: sync,
            isSyncEnabled: { syncEnabled },
            startsAutomatically: true
        )

        #expect(await drainGate.waitUntilStarted())
        syncEnabled = false
        manager.handleSyncDisabled()

        #expect(await drainGate.waitUntilCancelled())
        drainGate.resolve(())
        for _ in 0..<2_000 where sync.completedDrainCount == 0 {
            await Task.yield()
        }
        await Task.yield()

        #expect(sync.completedDrainCount == 1)
        #expect(remote.fetchCount == 0)
    }

    @Test
    func blockedStartupRecoveryDoesNotRetainOwner() async throws {
        let drainGate = ServerCancellationIgnoringGate<Void>()
        let sync = ServerSyncRepositoryFake()
        sync.drainHandler = { await drainGate.wait() }
        let remote = ServerRemoteRepositoryFake()
        var manager: ServerManager? = makeManager(
            local: try makePendingDeletionLocal(),
            remote: remote,
            sync: sync,
            isSyncEnabled: { true },
            startsAutomatically: true
        )
        weak var releasedManager: ServerManager?
        releasedManager = manager

        #expect(await drainGate.waitUntilStarted())
        manager = nil

        #expect(await drainGate.waitUntilCancelled())
        for _ in 0..<2_000 where releasedManager != nil {
            await Task.yield()
        }
        #expect(releasedManager == nil)
        #expect(remote.fetchCount == 0)

        drainGate.resolve(())
    }

    @Test
    func syncDisableDuringSchemaInitializationRejectsLateSaveCompletion() async {
        var syncEnabled = true
        let workspace = makeWorkspace(name: "Local")
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        let saveGate = ServerCancellationIgnoringGate<Void>()
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in throw ServerRemoteTestError.schema }
        remote.saveWorkspaceHandler = { _ in await saveGate.wait() }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { syncEnabled },
            isRemoteSchemaError: { _ in true }
        )
        let loadTask = Task { await manager.loadData() }

        #expect(await saveGate.waitUntilStarted())
        syncEnabled = false
        manager.handleSyncDisabled()

        #expect(await saveGate.waitUntilCancelled())
        saveGate.resolve(())
        await loadTask.value

        #expect(manager.workspaces == [workspace])
        #expect(manager.stateStore.loadState.phase == .idle)
        #expect(remote.savedWorkspaces == [workspace])
        #expect(remote.savedServers.isEmpty)
        #expect(sync.drainCount == 0)
    }

    @Test
    func schemaInitializationFailureLeavesCoordinatorReadyForRetry() async {
        let workspace = makeWorkspace(name: "Local")
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, fetchCount in
            if fetchCount == 1 {
                throw ServerRemoteTestError.schema
            }
            return ServerRemoteChanges(
                servers: [server],
                workspaces: [workspace],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: ServerRemoteChangeCheckpoint(
                    id: UUID(uuidString: "80000000-0000-0000-0000-000000000003")!
                )
            )
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true },
            isRemoteSchemaError: { _ in true }
        )

        await manager.loadData()

        #expect(remote.savedWorkspaces == [workspace])
        #expect(remote.savedServers == [server])
        guard case .failed = manager.stateStore.loadState.phase else {
            Issue.record("Expected the first schema load to fail after initialization")
            return
        }

        await manager.loadData()

        #expect(remote.fetchCount == 2)
        #expect(manager.workspaces == [workspace])
        #expect(manager.servers == [server])
        #expect(manager.stateStore.loadState.phase == .idle)
        #expect(sync.drainCount == 1)
    }

    @Test
    func independentManagersKeepRemoteCoordinatorsAndSnapshotsIsolated() async {
        let firstRemote = ServerRemoteRepositoryFake()
        firstRemote.fetchHandler = { _, _ in
            self.makeRemoteChanges(workspaceName: "First Remote")
        }
        let secondRemote = ServerRemoteRepositoryFake()
        secondRemote.fetchHandler = { _, _ in
            self.makeRemoteChanges(workspaceName: "Second Remote")
        }
        let firstSync = ServerSyncRepositoryFake()
        let secondSync = ServerSyncRepositoryFake()
        let firstDependencies = makeDependencies(
            local: nil,
            remote: firstRemote,
            sync: firstSync,
            isSyncEnabled: { true },
            isRemoteSchemaError: { _ in false }
        )
        let secondDependencies = makeDependencies(
            local: nil,
            remote: secondRemote,
            sync: secondSync,
            isSyncEnabled: { true },
            isRemoteSchemaError: { _ in false }
        )
        let firstManager = ServerManager(
            dependencies: firstDependencies,
            startsAutomatically: false
        )
        let secondManager = ServerManager(
            dependencies: secondDependencies,
            startsAutomatically: false
        )

        await firstManager.loadData()
        await secondManager.loadData()

        #expect(firstManager.workspaces.map(\.name) == ["First Remote"])
        #expect(secondManager.workspaces.map(\.name) == ["Second Remote"])
        #expect(firstManager.stateStore !== secondManager.stateStore)
        #expect(firstDependencies.remoteSyncCoordinator !== secondDependencies.remoteSyncCoordinator)
        #expect(firstSync.drainCount == 1)
        #expect(secondSync.drainCount == 1)
    }

    private func makeManager(
        local: ServerLocalRepositoryFake? = nil,
        remote: ServerRemoteRepositoryFake,
        sync: ServerSyncRepositoryFake,
        preferences: ServerManagerPreferencesFake? = nil,
        isSyncEnabled: @escaping () -> Bool,
        isRemoteSchemaError: @escaping (Error) -> Bool = { _ in false },
        startsAutomatically: Bool = false
    ) -> ServerManager {
        ServerManager(
            dependencies: makeDependencies(
                local: local,
                remote: remote,
                sync: sync,
                preferences: preferences,
                isSyncEnabled: isSyncEnabled,
                isRemoteSchemaError: isRemoteSchemaError
            ),
            startsAutomatically: startsAutomatically
        )
    }

    private func makeRemoteSyncCoordinator(
        local: ServerLocalRepositoryFake? = nil,
        remote: ServerRemoteRepositoryFake,
        sync: ServerSyncRepositoryFake,
        isSyncEnabled: @escaping () -> Bool,
        isRemoteSchemaError: @escaping (Error) -> Bool = { _ in false }
    ) -> ServerRemoteSyncCoordinator {
        makeDependencies(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: isSyncEnabled,
            isRemoteSchemaError: isRemoteSchemaError
        ).remoteSyncCoordinator
    }

    private func makeDependencies(
        local: ServerLocalRepositoryFake?,
        remote: ServerRemoteRepositoryFake,
        sync: ServerSyncRepositoryFake,
        preferences: ServerManagerPreferencesFake? = nil,
        isSyncEnabled: @escaping () -> Bool,
        isRemoteSchemaError: @escaping (Error) -> Bool
    ) -> ServerManagerDependencies {
        let now = { Date(timeIntervalSinceReferenceDate: 20_000) }
        let makeID = { UUID(uuidString: "90000000-0000-0000-0000-000000000002")! }
        let stateStore = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: local ?? ServerLocalRepositoryFake(servers: [], workspaces: []),
                preferences: preferences ?? ServerManagerPreferencesFake(),
                freePlanTracker: FreePlanAssignmentTrackerFake(),
                isSyncEnabled: isSyncEnabled,
                now: now,
                makeID: makeID,
                defaultWorkspaceName: { "My Servers" },
                canonicalDefaultWorkspaceNames: { ["My Servers"] }
            )
        )
        return ServerManagerDependencies(
            stateStore: stateStore,
            remoteRepository: remote,
            syncRepository: sync,
            credentialRepository: ServerManagerCredentialRepositoryFake(),
            actionAuthorizer: ProtectedServerActionAuthorizerFake(),
            knownHosts: ServerKnownHostRepositoryFake(),
            isRemoteSchemaError: isRemoteSchemaError,
            now: now,
            makeID: makeID
        )
    }

    @Test
    func queuePersistenceFailureIsReturnedWithoutStartingDrain() async {
        let workspace = makeWorkspace(name: "Local")
        let sync = ServerSyncRepositoryFake()
        sync.enqueueError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(
            local: ServerLocalRepositoryFake(servers: [], workspaces: [workspace]),
            remote: ServerRemoteRepositoryFake(),
            sync: sync,
            isSyncEnabled: { true }
        )
        let server = makeServer(workspaceID: workspace.id)

        await #expect(throws: ServerSyncRepositoryTestError.self) {
            try await manager.apply(.create(server))
        }

        #expect(sync.drainCount == 0)
    }

    private func makeWorkspace(name: String) -> Workspace {
        Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            name: name,
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeServer(workspaceID: UUID) -> Server {
        Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
            workspaceId: workspaceID,
            name: "Server",
            host: "server.example.test",
            username: "root",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeRemoteChanges(
        workspaceName: String,
        checkpoint: ServerRemoteChangeCheckpoint = ServerRemoteChangeCheckpoint(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
        )
    ) -> ServerRemoteChanges {
        ServerRemoteChanges(
            servers: [],
            workspaces: [
                Workspace(
                    name: workspaceName,
                    order: 0,
                    createdAt: .distantPast,
                    updatedAt: .distantPast
                )
            ],
            deletedServerIDs: [],
            deletedWorkspaceIDs: [],
            isFullFetch: true,
            checkpoint: checkpoint
        )
    }

    private func makePendingDeletionLocal() throws -> ServerLocalRepositoryFake {
        let workspace = Workspace(
            name: "Pending Deletion",
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let plan = try #require(WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: [],
            workspaces: [workspace],
            id: UUID(),
            mutationIDs: [UUID()],
            mutationDate: .distantPast
        ))
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        local.journal = WorkspaceDeletionJournal(plan: plan)
        return local
    }
}

