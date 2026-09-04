import ETSession
import Foundation
import MoshCore
import Testing
@testable import VVTerm

private actor LiveCompositionRemoteSessionSpy: TerminalRemoteSessionServicing {
    nonisolated let backendMetadata = [RemoteSessionBackendMetadata(
        identifier: .tmux,
        displayName: "tmux",
        installation: .automatic,
        managedStartupCommandSupport: .supported
    )]
    private var killedIdentifiers: [RemoteSessionIdentifier] = []

    func killedSessions() -> [RemoteSessionIdentifier] {
        killedIdentifiers
    }

    func availability(
        for backendIdentifier: RemoteSessionBackendIdentifier,
        using client: SSHClient
    ) async -> RemoteSessionAvailability {
        .unsupportedEnvironment
    }

    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        []
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) async throws -> RemoteSessionBackendLaunchPlan {
        throw SSHError.notConnected
    }

    func installScript(
        attachment: RemoteSessionAttachment,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        using client: SSHClient,
        attachAfterInstall: Bool
    ) async -> String? { nil }

    func sendScript(
        _ script: String,
        using client: SSHClient,
        shellId: UUID
    ) async throws {}

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async {
        killedIdentifiers.append(identifier)
    }

    func cleanupSessions(
        keeping identifiers: @escaping @Sendable () async throws -> Set<RemoteSessionIdentifier>,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {}

    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async -> String? {
        nil
    }
}

private actor LiveCompositionRemoteMoshSpy: TerminalRemoteMoshServicing {
    func installMoshServer(using client: SSHClient) async throws {}
}

private final class LiveCompositionEternalTerminalResumeStore:
    EternalTerminalResumeStoring,
    @unchecked Sendable
{
    let checkpointPaneIDs: Set<UUID>

    init(checkpointPaneIDs: Set<UUID>) {
        self.checkpointPaneIDs = checkpointPaneIDs
    }

    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? { nil }
    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { checkpointPaneIDs.contains(paneId) }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

private final class LiveCompositionMoshResumeStore: MoshResumeStoring {
    let checkpointPaneIDs: Set<UUID>

    init(checkpointPaneIDs: Set<UUID>) {
        self.checkpointPaneIDs = checkpointPaneIDs
    }

    func snapshot(for paneId: UUID) throws -> MoshSnapshot? { nil }
    func hasSnapshot(for paneId: UUID) -> Bool { checkpointPaneIDs.contains(paneId) }
    func save(_ snapshot: MoshSnapshot, for paneId: UUID) throws {}
    func deleteSnapshot(for paneId: UUID) throws {}
}

@MainActor
private final class LiveCompositionLiveActivityController: TerminalLiveActivityControlling {
    private(set) var targets: [TerminalLiveActivityTarget] = []

    func reconcile(toward target: TerminalLiveActivityTarget) async {
        targets.append(target)
    }

    func endForApplicationTermination() -> Bool {
        true
    }
}

@MainActor
private final class LiveCompositionBiometricAuthService: BiometricAuthServing {
    func availability() -> BiometricAvailability {
        .unavailable(.notAvailable)
    }

    func authenticate(
        reason: BiometricAuthenticationReason,
        allowPasscodeFallback: Bool
    ) async throws {}
}

@Suite(.serialized)
@MainActor
struct TerminalTabManagerLiveCompositionTests {
    @Test
    func explicitInputsKeepManagerOwnersIndependent() async throws {
        let firstSuiteName = "TerminalTabManagerLiveCompositionTests.\(UUID().uuidString)"
        let secondSuiteName = "TerminalTabManagerLiveCompositionTests.\(UUID().uuidString)"
        let firstDefaults = try #require(UserDefaults(suiteName: firstSuiteName))
        let secondDefaults = try #require(UserDefaults(suiteName: secondSuiteName))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuiteName)
            secondDefaults.removePersistentDomain(forName: secondSuiteName)
        }
        firstDefaults.set(true, forKey: "terminalTmuxEnabledDefault")
        secondDefaults.set(false, forKey: "terminalTmuxEnabledDefault")

        let firstCheckpointPaneID = UUID()
        let secondCheckpointPaneID = UUID()
        let firstRemoteSessions = LiveCompositionRemoteSessionSpy()
        let secondRemoteSessions = LiveCompositionRemoteSessionSpy()
        let firstSurfaceStore = GhosttyTerminalSurfaceStore()
        let secondSurfaceStore = GhosttyTerminalSurfaceStore()
        let firstLiveActivityController = LiveCompositionLiveActivityController()
        let secondLiveActivityController = LiveCompositionLiveActivityController()
        let first = makeManager(
            defaults: firstDefaults,
            remoteSessions: firstRemoteSessions,
            eternalTerminalResumeStore: LiveCompositionEternalTerminalResumeStore(
                checkpointPaneIDs: [firstCheckpointPaneID]
            ),
            moshResumeStore: LiveCompositionMoshResumeStore(
                checkpointPaneIDs: [firstCheckpointPaneID]
            ),
            surfaceStore: firstSurfaceStore,
            liveActivityController: firstLiveActivityController,
            applicationIsActive: false
        )
        let second = makeManager(
            defaults: secondDefaults,
            remoteSessions: secondRemoteSessions,
            eternalTerminalResumeStore: LiveCompositionEternalTerminalResumeStore(
                checkpointPaneIDs: [secondCheckpointPaneID]
            ),
            moshResumeStore: LiveCompositionMoshResumeStore(
                checkpointPaneIDs: [secondCheckpointPaneID]
            ),
            surfaceStore: secondSurfaceStore,
            liveActivityController: secondLiveActivityController,
            applicationIsActive: true
        )

        let firstOwnsSurfaceStore =
            (first.terminalSurfaceStore as AnyObject) === firstSurfaceStore
        let secondOwnsSurfaceStore =
            (second.terminalSurfaceStore as AnyObject) === secondSurfaceStore
        #expect(firstOwnsSurfaceStore)
        #expect(secondOwnsSurfaceStore)
        #expect(first.remoteSessionCoordinator.isEnabled(for: UUID()))
        #expect(!second.remoteSessionCoordinator.isEnabled(for: UUID()))
        #expect(first.remoteSessionCoordinator.backendIdentifier(for: UUID()) == .tmux)
        #expect(second.remoteSessionCoordinator.backendIdentifier(for: UUID()) == .tmux)
        #expect(firstDefaults.bool(forKey: TerminalRemoteSessionDefaults.enabledKey))
        #expect(!secondDefaults.bool(forKey: TerminalRemoteSessionDefaults.enabledKey))
        #expect(!first.reconnectCoordinator.applicationIsActive)
        #expect(second.reconnectCoordinator.applicationIsActive)
        #expect(
            first.transportCoordinator.hasEternalTerminalCheckpoint(
                for: firstCheckpointPaneID
            )
        )
        #expect(
            !first.transportCoordinator.hasEternalTerminalCheckpoint(
                for: secondCheckpointPaneID
            )
        )
        #expect(first.transportCoordinator.hasMoshCheckpoint(for: firstCheckpointPaneID))
        #expect(!first.transportCoordinator.hasMoshCheckpoint(for: secondCheckpointPaneID))
        #expect(
            second.transportCoordinator.hasEternalTerminalCheckpoint(
                for: secondCheckpointPaneID
            )
        )
        #expect(second.transportCoordinator.hasMoshCheckpoint(for: secondCheckpointPaneID))

        let identifier = try RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "first-session"
        )
        await first.remoteSessionCoordinator.killSession(
            identifier,
            using: SSHClient.testing()
        )
        #expect(await firstRemoteSessions.killedSessions() == [identifier])
        #expect(await secondRemoteSessions.killedSessions().isEmpty)

        let tab = TerminalTab(serverId: UUID(), title: "First")
        first.sessionState.install(
            tab,
            paneState: TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            ),
            select: true
        )
        first.sessionState.persistAndRestoreSnapshotForTesting()
        #expect(firstDefaults.data(forKey: "terminalTabsSnapshot.v1") != nil)
        #expect(secondDefaults.data(forKey: "terminalTabsSnapshot.v1") == nil)
        #expect(await waitUntil {
            !firstLiveActivityController.targets.isEmpty
                && !secondLiveActivityController.targets.isEmpty
        })

        await first.resetForTesting()
        await second.resetForTesting()
    }

    private func makeManager(
        defaults: UserDefaults,
        remoteSessions: LiveCompositionRemoteSessionSpy,
        eternalTerminalResumeStore: LiveCompositionEternalTerminalResumeStore,
        moshResumeStore: LiveCompositionMoshResumeStore,
        surfaceStore: GhosttyTerminalSurfaceStore,
        liveActivityController: LiveCompositionLiveActivityController,
        applicationIsActive: Bool
    ) -> TerminalTabManager {
        let analyticsTracker = AnalyticsTracker.shared
        let applicationIsActiveQuery: @MainActor @Sendable () -> Bool = {
            applicationIsActive
        }
        let appLockManager = AppLockManager(
            defaults: defaults,
            authService: LiveCompositionBiometricAuthService()
        )
        let cloudKitSync = CloudKitSyncLiveComposition.makeLive(
            transport: CloudKitManager.shared,
            terminalFontRepository: LocalTerminalFontRepository.applicationSupport(
                defaults: defaults
            ),
            defaults: defaults,
            now: Date.init,
            makeID: UUID.init
        )
        let serverManager = ServerManager(
            dependencies: .live(
                defaults: defaults,
                serverCloud: cloudKitSync.serverCloud,
                credentialRepository: KeychainManager.shared,
                knownHosts: KnownHostsManager.shared,
                freePlanTracker: analyticsTracker,
                actionAuthorizer: appLockManager,
                syncRepository: cloudKitSync.coordinator,
                didDeleteServerLocalData: { _ in },
                defaultWorkspaceName: { "Default" },
                now: Date.init,
                makeID: UUID.init
            ),
            startsAutomatically: false
        )
        return TerminalTabManagerLiveComposition.makeManager(
            defaults: defaults,
            sshClientFactory: .testing(),
            networkMonitor: .shared,
            appLockManager: appLockManager,
            serverManager: serverManager,
            prepareInitialConnection: { _ in },
            engagementTracker: EngagementTracker(
                dependencies: .live(
                    defaults: defaults,
                    analytics: analyticsTracker,
                    now: Date.init,
                    calendar: .current,
                    applicationIsActive: applicationIsActiveQuery
                )
            ),
            analyticsTracker: analyticsTracker,
            liveActivityManager: LiveActivityManager(
                controller: liveActivityController
            ),
            remoteMosh: LiveCompositionRemoteMoshSpy(),
            remoteSessions: remoteSessions,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshResumeStore: moshResumeStore,
            terminalSurfaceStore: surfaceStore,
            deviceID: UUID().uuidString.lowercased(),
            themeStyle: {
                TerminalRemoteSessionLiveComposition.themeStyle(for: "Aizen Dark")
            },
            applicationIsActive: applicationIsActiveQuery
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}
