import CloudKit
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ServerManagerBootstrapTests {
    @Test
    func syncEnabledFreshInstallWaitsForRemoteStateBeforeCreatingWorkspace() {
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()

        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: ServerRemoteRepositoryFake(isAvailable: true),
            sync: ServerSyncRepositoryFake()
        )

        #expect(manager.workspaces.isEmpty)
        #expect(local.workspaces.isEmpty)
        #expect(
            manager.stateStore.initialWorkspaceBootstrapState
                == .awaitingAuthoritativeRemoteState
        )
    }

    @Test
    func localOnlyFreshInstallCreatesOneStableInitialWorkspace() {
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()

        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: ServerRemoteRepositoryFake(),
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { false }
        )

        #expect(manager.workspaces.map(\.id) == [InitialWorkspaceBootstrapState.workspaceID])
        #expect(local.workspaces == manager.workspaces)
        #expect(preferences.hasResolvedInitialWorkspace)
        #expect(manager.stateStore.initialWorkspaceBootstrapState == .inactive)
    }

    @Test
    func disablingSyncCreatesOneInitialWorkspaceForFreshLocalUse() {
        var syncEnabled = true
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()
        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: ServerRemoteRepositoryFake(isAvailable: true),
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { syncEnabled }
        )

        syncEnabled = false
        manager.handleSyncDisabled()

        #expect(manager.workspaces.map(\.id) == [InitialWorkspaceBootstrapState.workspaceID])
        #expect(local.workspaces == manager.workspaces)
        #expect(preferences.hasResolvedInitialWorkspace)
    }

    @Test
    func disablingSyncKeepsAWorkspaceCreatedWhileRemoteLoadWasPending() async throws {
        var syncEnabled = true
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()
        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: ServerRemoteRepositoryFake(isAvailable: true),
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { syncEnabled }
        )
        let workspace = Workspace(id: UUID(), name: "Custom", order: 0)

        try await manager.addWorkspace(workspace, hasProAccess: false)
        syncEnabled = false
        manager.handleSyncDisabled()

        #expect(manager.workspaces.map(\.id) == [workspace.id])
        #expect(local.workspaces.map(\.id) == [workspace.id])
        #expect(preferences.hasResolvedInitialWorkspace)
    }

    @Test
    func existingRemoteWorkspacesPreventInitialWorkspaceAndRemainUnchanged() async {
        let remoteWorkspaces = [
            Workspace(id: UUID(), name: "Remote One", order: 0),
            Workspace(id: UUID(), name: "Remote Two", order: 1)
        ]
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { forceFullFetch, _ in
            #expect(forceFullFetch)
            return self.remoteChanges(workspaces: remoteWorkspaces)
        }
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager.loadData()

        #expect(manager.workspaces == remoteWorkspaces)
        #expect(local.workspaces == remoteWorkspaces)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(preferences.hasResolvedInitialWorkspace)
        #expect(remote.acceptedCheckpoints.count == 1)
    }

    @Test
    func authoritativeEmptyRemoteStateCreatesOneInitialWorkspace() async throws {
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in self.remoteChanges() }
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager.loadData()

        let workspace = try #require(manager.workspaces.first)
        #expect(manager.workspaces.count == 1)
        #expect(workspace.id == InitialWorkspaceBootstrapState.workspaceID)
        #expect(local.workspaces == [workspace])
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(remote.initialWorkspaceCandidates == [workspace])
        #expect(remote.savedWorkspaces.isEmpty)
        #expect(preferences.hasResolvedInitialWorkspace)
        #expect(remote.acceptedCheckpoints.count == 1)
        #expect(sync.drainCount == 1)
    }

    @Test
    func concurrentLoadsCreateOneInitialWorkspace() async {
        let gate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in await gate.wait() }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: ServerLocalRepositoryFake(servers: [], workspaces: []),
            preferences: freshInstallPreferences(),
            remote: remote,
            sync: sync
        )
        let firstLoad = Task { await manager.loadData() }
        #expect(await gate.waitUntilStarted())
        let secondLoad = Task { await manager.loadData() }
        await Task.yield()

        #expect(remote.fetchCount == 1)
        gate.resolve(remoteChanges())
        await firstLoad.value
        await secondLoad.value

        #expect(manager.workspaces.count == 1)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(remote.initialWorkspaceCandidates.count == 1)
    }

    @Test
    func separateFreshStartsUseTheSameInitialWorkspaceIdentity() async throws {
        let first = makeFreshEmptyRemoteManager()
        let second = makeFreshEmptyRemoteManager()

        await first.manager.loadData()
        await second.manager.loadData()

        let firstWorkspace = try #require(first.manager.workspaces.first)
        let secondWorkspace = try #require(second.manager.workspaces.first)
        #expect(firstWorkspace.id == secondWorkspace.id)
        #expect(firstWorkspace.id == InitialWorkspaceBootstrapState.workspaceID)
    }

    @Test
    func failedRemoteEstablishmentDoesNotCreateInitialWorkspace() async {
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, fetchCount in
            if fetchCount == 1 {
                throw CKError(.zoneNotFound)
            }
            return self.remoteChanges()
        }
        let preferences = freshInstallPreferences()
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: ServerLocalRepositoryFake(servers: [], workspaces: []),
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager.loadData()

        #expect(manager.workspaces.isEmpty)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(!preferences.hasResolvedInitialWorkspace)
        #expect(
            manager.stateStore.initialWorkspaceBootstrapState
                == .awaitingAuthoritativeRemoteState
        )

        await manager.loadData()

        #expect(manager.workspaces.count == 1)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(remote.initialWorkspaceCandidates.count == 1)
    }

    @Test
    func incompleteRemoteStateDoesNotCreateOrCompleteInitialWorkspace() async {
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in self.remoteChanges(isFullFetch: false) }
        let preferences = freshInstallPreferences()
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: ServerLocalRepositoryFake(servers: [], workspaces: []),
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager.loadData()

        #expect(manager.workspaces.isEmpty)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(remote.acceptedCheckpoints.isEmpty)
        #expect(!preferences.hasResolvedInitialWorkspace)
        #expect(
            manager.stateStore.initialWorkspaceBootstrapState
                == .awaitingAuthoritativeRemoteState
        )
    }

    @Test
    func relaunchKeepsSuccessfulInitialWorkspaceIdentity() async throws {
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in self.remoteChanges() }
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()
        let sync = ServerSyncRepositoryFake()
        var manager: ServerManager? = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager?.loadData()
        let initialWorkspace = try #require(manager?.workspaces.first)
        manager = nil

        remote.fetchHandler = { _, _ in self.remoteChanges(workspaces: [initialWorkspace]) }
        let relaunchedManager = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )
        await relaunchedManager.loadData()

        #expect(relaunchedManager.workspaces == [initialWorkspace])
        #expect(sync.enqueuedServerMutations.isEmpty)
    }

    @Test
    func workspaceCreatedRemotelyAfterEmptyFetchWinsWithoutBeingOverwritten() async throws {
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in self.remoteChanges() }
        var remoteWorkspace = Workspace(
            id: InitialWorkspaceBootstrapState.workspaceID,
            name: "Renamed Remotely",
            colorHex: "#FF9500",
            order: 0
        )
        remoteWorkspace.environments = [
            ServerEnvironment(
                id: UUID(),
                name: "Remote",
                shortName: "REM",
                colorHex: "#FF9500",
                isBuiltIn: false
            )
        ]
        remote.createWorkspaceIfAbsentHandler = { _ in remoteWorkspace }
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager.loadData()

        #expect(manager.workspaces == [remoteWorkspace])
        #expect(local.workspaces == [remoteWorkspace])
        #expect(remote.initialWorkspaceCandidates.count == 1)
        #expect(remote.savedWorkspaces.isEmpty)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(preferences.hasResolvedInitialWorkspace)
    }

    @Test
    func localEditWhileInitialCreateIsRunningWinsAndUsesNormalUpdate() async throws {
        let createGate = ServerCancellationIgnoringGate<Workspace>()
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in self.remoteChanges() }
        remote.createWorkspaceIfAbsentHandler = { _ in await createGate.wait() }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: ServerLocalRepositoryFake(servers: [], workspaces: []),
            preferences: freshInstallPreferences(),
            remote: remote,
            sync: sync
        )
        let load = Task { await manager.loadData() }
        #expect(await createGate.waitUntilStarted())
        var editedWorkspace = try #require(manager.workspaces.first)
        editedWorkspace.name = "Edited While Syncing"

        try await manager.updateWorkspace(editedWorkspace)
        let remoteWorkspace = Workspace(
            id: editedWorkspace.id,
            name: "Remote Result",
            order: 0
        )
        createGate.resolve(remoteWorkspace)
        await load.value

        #expect(manager.workspaces == [editedWorkspace])
        #expect(sync.enqueuedServerMutations.count == 1)
        guard case .workspaceUpsert(let pendingWorkspace) = try #require(
            sync.enqueuedServerMutations.first
        ).payload else {
            Issue.record("Expected the local edit to replace the initial create action")
            return
        }
        #expect(pendingWorkspace == editedWorkspace)
    }

    @Test
    func failedInitialWorkspaceCreateRetriesWithoutAddingAnotherWorkspace() async throws {
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in self.remoteChanges() }
        remote.createWorkspaceIfAbsentHandler = { workspace in
            if remote.initialWorkspaceCandidates.count == 1 {
                throw ServerRemoteTestError.schema
            }
            return workspace
        }
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager.loadData()

        #expect(manager.workspaces.map(\.id) == [InitialWorkspaceBootstrapState.workspaceID])
        #expect(sync.enqueuedServerMutations.count == 1)
        guard case .initialWorkspaceCreate = try #require(
            sync.enqueuedServerMutations.first
        ).payload else {
            Issue.record("Expected one pending initial workspace create")
            return
        }
        #expect(!preferences.hasResolvedInitialWorkspace)

        await manager.loadData()

        #expect(manager.workspaces.count == 1)
        #expect(remote.initialWorkspaceCandidates.count == 2)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(preferences.hasResolvedInitialWorkspace)
    }

    @Test
    func unresolvedInitialWorkspaceRelaunchUsesNewRemoteDataWithoutCreatingAgain() async {
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in self.remoteChanges() }
        remote.createWorkspaceIfAbsentHandler = { _ in
            throw ServerRemoteTestError.schema
        }
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        let preferences = freshInstallPreferences()
        let sync = ServerSyncRepositoryFake()
        var manager: ServerManager? = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager?.loadData()
        #expect(sync.enqueuedServerMutations.count == 1)
        preferences.hasSeenWelcome = true
        manager = nil

        let remoteWorkspace = Workspace(id: UUID(), name: "Synced Workspace", order: 0)
        remote.fetchHandler = { forceFullFetch, _ in
            #expect(forceFullFetch)
            return self.remoteChanges(workspaces: [remoteWorkspace])
        }
        let relaunchedManager = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        #expect(
            relaunchedManager.stateStore.initialWorkspaceBootstrapState
                == .awaitingAuthoritativeRemoteState
        )
        await relaunchedManager.loadData()

        #expect(relaunchedManager.workspaces == [remoteWorkspace])
        #expect(local.workspaces == [remoteWorkspace])
        #expect(remote.initialWorkspaceCandidates.count == 1)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(preferences.hasResolvedInitialWorkspace)
    }

    @Test
    func unresolvedInitialWorkspaceWithoutPendingActionRetriesSafely() async {
        let initialWorkspace = Workspace(
            id: InitialWorkspaceBootstrapState.workspaceID,
            name: "My Servers",
            order: 0
        )
        let local = ServerLocalRepositoryFake(
            servers: [],
            workspaces: [initialWorkspace]
        )
        let preferences = freshInstallPreferences()
        preferences.hasSeenWelcome = true
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { forceFullFetch, _ in
            #expect(forceFullFetch)
            return self.remoteChanges()
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            preferences: preferences,
            remote: remote,
            sync: sync
        )

        await manager.loadData()

        #expect(manager.stateStore.ambiguousCloudRecovery == nil)
        #expect(manager.workspaces.map(\.id) == [InitialWorkspaceBootstrapState.workspaceID])
        #expect(remote.initialWorkspaceCandidates.count == 1)
        #expect(sync.enqueuedServerMutations.isEmpty)
        #expect(preferences.hasResolvedInitialWorkspace)
    }

    private func makeFreshEmptyRemoteManager() -> (
        manager: ServerManager,
        sync: ServerSyncRepositoryFake
    ) {
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in self.remoteChanges() }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: ServerLocalRepositoryFake(servers: [], workspaces: []),
            preferences: freshInstallPreferences(),
            remote: remote,
            sync: sync
        )
        return (manager, sync)
    }

    private func makeManager(
        local: ServerLocalRepositoryFake,
        preferences: ServerManagerPreferencesFake,
        remote: ServerRemoteRepositoryFake,
        sync: ServerSyncRepositoryFake,
        isSyncEnabled: @escaping () -> Bool = { true }
    ) -> ServerManager {
        let now = { Date(timeIntervalSinceReferenceDate: 20_000) }
        let stateStore = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: local,
                preferences: preferences,
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
                remoteRepository: remote,
                syncRepository: sync,
                credentialRepository: ServerManagerCredentialRepositoryFake(),
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

    private func freshInstallPreferences() -> ServerManagerPreferencesFake {
        let preferences = ServerManagerPreferencesFake()
        preferences.hasResolvedInitialWorkspace = false
        preferences.hasSeenWelcome = false
        return preferences
    }

    private func remoteChanges(
        workspaces: [Workspace] = [],
        isFullFetch: Bool = true
    ) -> ServerRemoteChanges {
        ServerRemoteChanges(
            servers: [],
            workspaces: workspaces,
            deletedServerIDs: [],
            deletedWorkspaceIDs: [],
            isFullFetch: isFullFetch,
            checkpoint: ServerRemoteChangeCheckpoint(id: UUID())
        )
    }
}
