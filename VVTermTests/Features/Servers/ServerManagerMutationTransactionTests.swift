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

@MainActor
private final class ServerCancellationIgnoringGate<Value> {
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
private final class ServerSyncRepositoryFake: ServerSyncRepository {
    var enqueuedServerUpserts: [Server] = []
    private(set) var drainCount = 0
    private(set) var completedDrainCount = 0
    var drainHandler: (@MainActor () async -> Void)?

    func pendingServerMutations() -> [ServerPendingMutation] { [] }
    func clearPendingServerAndWorkspaceMutations() {}
    func removePendingServerMutation(_ mutationID: UUID) {}
    func enqueueServerUpsert(_ server: Server) { enqueuedServerUpserts.append(server) }
    func enqueueServerDelete(_ server: Server) {}
    func enqueueWorkspaceUpsert(_ workspace: Workspace) {}
    func enqueueWorkspaceDelete(_ workspace: Workspace) {}
    func drainPendingMutations() async {
        drainCount += 1
        await drainHandler?()
        completedDrainCount += 1
    }
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

private enum ServerRemoteTestError: Error {
    case schema
}
