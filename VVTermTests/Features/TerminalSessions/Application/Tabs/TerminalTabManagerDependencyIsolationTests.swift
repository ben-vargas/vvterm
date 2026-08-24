import Combine
import ETSession
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class DependencyTestSnapshotStore: TerminalTabSnapshotStoring {
    private var data: Data?

    func loadSnapshotData() -> Data? {
        data
    }

    func saveSnapshotData(_ data: Data) {
        self.data = data
    }

    func removeSnapshotData() {
        data = nil
    }
}

private final class DependencyTestETResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? { nil }
    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { false }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

private actor TerminalAuthorizationGate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if continuation != nil { return true }
            await Task.yield()
        }
        return continuation != nil
    }

    func resolve(_ result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class TerminalEffectRecorder {
    var authorizeResult = true
    var authorizationGate: TerminalAuthorizationGate?
    private(set) var authorizationRequests: [UUID] = []
    private(set) var liveActivityRefreshCount = 0
    private(set) var successfulConnections: [(UUID, String)] = []
    private(set) var sessionEndStates: [Bool] = []
    private(set) var splitPaneCount = 0

    func effects() -> TerminalSessionApplicationEffects {
        TerminalSessionApplicationEffects(
            authorizeServer: { [self] server in
                authorizationRequests.append(server.id)
                if let authorizationGate {
                    return await authorizationGate.wait()
                }
                return authorizeResult
            },
            refreshLiveActivity: { [self] _ in
                liveActivityRefreshCount += 1
            },
            recordSuccessfulConnection: { [self] id, transport in
                successfulConnections.append((id, transport))
            },
            noteTerminalSessionEnded: { [self] otherTerminalsActive in
                sessionEndStates.append(otherTerminalsActive)
            },
            recordSplitPaneCreated: { [self] in
                splitPaneCount += 1
            }
        )
    }
}

private actor RecordingTerminalRemoteTmuxService: TerminalRemoteSessionServicing {
    nonisolated let backendMetadata = [RemoteSessionBackendMetadata(
        identifier: .tmux,
        displayName: "tmux",
        installation: .automatic
    )]
    private var killedSessions: [RemoteSessionIdentifier] = []
    private var availabilityProbes = 0

    func killedSessionIdentifiers() -> [RemoteSessionIdentifier] {
        killedSessions
    }

    func availabilityProbeCount() -> Int {
        availabilityProbes
    }

    func availability(
        for backendIdentifier: RemoteSessionBackendIdentifier,
        using client: SSHClient
    ) async -> RemoteSessionAvailability {
        availabilityProbes += 1
        return .unsupportedEnvironment
    }

    func listSessions(
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        []
    }

    func prepareManagedSession(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        runtime: RemoteSessionRuntime
    ) async {}

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
        killedSessions.append(identifier)
    }

    func cleanupSessions(
        deviceID: String,
        keeping identifiers: Set<RemoteSessionIdentifier>,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {}

    func currentWorkingDirectory(
        for identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async -> String? {
        nil
    }
}

private actor RecordingTerminalRemoteMoshService: TerminalRemoteMoshServicing {
    private var installationCount = 0

    func installCount() -> Int {
        installationCount
    }

    func installMoshServer(using client: SSHClient) async throws {
        installationCount += 1
    }
}

@Suite(.serialized)
@MainActor
struct TerminalTabManagerDependencyIsolationTests {
    @Test
    func disconnectInvalidatesAuthorizedTabOpenBeforeItMutatesSessionState() async throws {
        let effects = TerminalEffectRecorder()
        let gate = TerminalAuthorizationGate()
        effects.authorizationGate = gate
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: effects,
            remoteSessions: RecordingTerminalRemoteTmuxService(),
            remoteMosh: RecordingTerminalRemoteMoshService(),
            deviceID: "tab-open-generation"
        )
        let server = makeServer()
        let staleOpen = Task {
            try await manager.openTab(for: server)
        }
        #expect(await gate.waitUntilBlocked())

        manager.disconnectServer(server.id)
        effects.authorizationGate = nil
        let replacement = try await manager.openTab(for: server)
        await gate.resolve(true)

        do {
            _ = try await staleOpen.value
            Issue.record("The stale authorized tab open should be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(manager.sessionState.tabs(for: server.id) == [replacement])
        await manager.resetForTesting()
    }

    @Test
    func disabledTmuxProducesPlainStartupPlanWithoutRemoteProbe() async throws {
        let remoteSessions = RecordingTerminalRemoteTmuxService()
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(),
            remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(),
            deviceID: "skip-device"
        )
        let tab = TerminalTab(serverId: UUID(), title: "Skip tmux")
        install(tab, in: manager)
        let client = SSHClient.testing()
        let startToken = try #require(
            manager.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client)
        )

        let plan = try await manager.remoteSessionCoordinator.startupPlan(
            for: tab.rootPaneId,
            serverID: tab.serverId,
            client: client,
            startToken: startToken
        )

        #expect(plan.command == nil)
        #expect(plan.remoteSessionLifecycle == nil)
        #expect(await remoteSessions.availabilityProbeCount() == 0)
        manager.transportCoordinator.finishShellStart(
            for: tab.rootPaneId,
            client: client,
            startToken: startToken
        )
        await manager.resetForTesting()
    }

    @Test
    func independentManagersRouteEffectsAndRuntimeServicesOnlyToTheirOwners() async throws {
        let firstNetwork = PassthroughSubject<TerminalNetworkReadiness, Never>()
        let secondNetwork = PassthroughSubject<TerminalNetworkReadiness, Never>()
        let firstEffects = TerminalEffectRecorder()
        let secondEffects = TerminalEffectRecorder()
        let firstTmux = RecordingTerminalRemoteTmuxService()
        let secondTmux = RecordingTerminalRemoteTmuxService()
        let firstMosh = RecordingTerminalRemoteMoshService()
        let secondMosh = RecordingTerminalRemoteMoshService()
        let first = makeManager(
            network: firstNetwork,
            effects: firstEffects,
            remoteSessions: firstTmux,
            remoteMosh: firstMosh,
            deviceID: "first-device"
        )
        let second = makeManager(
            network: secondNetwork,
            effects: secondEffects,
            remoteSessions: secondTmux,
            remoteMosh: secondMosh,
            deviceID: "second-device"
        )

        firstNetwork.send(.ready)
        #expect(first.reconnectCoordinator.currentNetworkReadiness == .ready)
        #expect(second.reconnectCoordinator.currentNetworkReadiness == .unknown)

        firstEffects.authorizeResult = false
        do {
            _ = try await first.openTab(for: makeServer())
            Issue.record("The injected access denial should stop the tab open")
        } catch {
            #expect(firstEffects.authorizationRequests.count == 1)
        }
        #expect(first.sessionState.serverIdsWithTabs.isEmpty)
        #expect(secondEffects.authorizationRequests.isEmpty)

        let tab = TerminalTab(serverId: UUID(), title: "First manager")
        install(tab, in: first)
        #expect(first.splitRight(
            tab: tab,
            paneId: tab.rootPaneId,
            hasProAccess: true
        ) != nil)
        first.updatePaneState(tab.rootPaneId, connectionState: .connected)

        let client = SSHClient.testing()
        let startToken = try #require(
            first.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client)
        )
        #expect(await first.transportCoordinator.registerSSHClient(
            client,
            shellId: UUID(),
            startToken: startToken,
            for: tab.rootPaneId,
            serverId: tab.serverId
        ))
        first.remoteSessionCoordinator.setAttachment(
            for: tab.rootPaneId,
            identifier: try! RemoteSessionIdentifier(
                backendIdentifier: .tmux,
                validating: "first-session"
            ),
            ownership: .managed
        )

        try await first.transportCoordinator.installMoshServer(for: tab.rootPaneId)
        first.remoteSessionCoordinator.killIfNeeded(for: tab.rootPaneId)
        #expect(await waitUntil {
            await firstTmux.killedSessionIdentifiers().map(\.rawValue) == ["first-session"]
        })
        await first.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)
        first.closeTab(tab)

        #expect(firstEffects.liveActivityRefreshCount > 1)
        #expect(firstEffects.successfulConnections.map(\.0) == [tab.rootPaneId])
        #expect(firstEffects.sessionEndStates == [false])
        #expect(firstEffects.splitPaneCount == 1)
        #expect(secondEffects.liveActivityRefreshCount == 1)
        #expect(secondEffects.successfulConnections.isEmpty)
        #expect(secondEffects.sessionEndStates.isEmpty)
        #expect(secondEffects.splitPaneCount == 0)
        #expect(await firstMosh.installCount() == 1)
        #expect(await secondMosh.installCount() == 0)
        #expect(await secondTmux.killedSessionIdentifiers().isEmpty)
        #expect(
            try! first.remoteSessionCoordinator.resolver.managedIdentifier(
                for: tab.rootPaneId,
                serverID: tab.serverId,
                backendIdentifier: .tmux
            ) != second.remoteSessionCoordinator.resolver.managedIdentifier(
                for: tab.rootPaneId,
                serverID: tab.serverId,
                backendIdentifier: .tmux
            )
        )

        await first.resetForTesting()
        await second.resetForTesting()
    }

    private func makeManager(
        network: PassthroughSubject<TerminalNetworkReadiness, Never>,
        effects: TerminalEffectRecorder,
        remoteSessions: RecordingTerminalRemoteTmuxService,
        remoteMosh: RecordingTerminalRemoteMoshService,
        deviceID: String
    ) -> TerminalTabManager {
        TerminalTabManager(
            snapshotStore: DependencyTestSnapshotStore(),
            dependencies: TerminalTabManagerDependencies(
                sshClientFactory: .testing(),
                networkReadiness: TerminalNetworkReadinessSource(
                    initial: .unknown,
                    updates: network.eraseToAnyPublisher()
                ),
                applicationIsActive: { true },
                appLock: TerminalAppLockSource(
                    initialIsLocked: false,
                    updates: Empty<Bool, Never>().eraseToAnyPublisher()
                ),
                effects: effects.effects(),
                remoteMosh: remoteMosh,
                eternalTerminalRuntime: .testing
            ),
            remoteSessionConfiguration: TerminalRemoteSessionConfiguration(
                deviceID: deviceID,
                enabledByDefault: { false },
                backendIdentifierByDefault: { .tmux },
                startupBehaviorByDefault: { .plainShell },
                serverSettings: { _ in nil },
                themeStyle: { TerminalRemoteSessionLiveComposition.themeStyle(for: nil) }
            ),
            remoteSessions: remoteSessions,
            terminalSurfaceStore: GhosttyTerminalSurfaceStore(),
            eternalTerminalResumeStore: DependencyTestETResumeStore(),
            moshRecovery: UnavailableTerminalMoshRecoveryService()
        )
    }

    private func install(_ tab: TerminalTab, in manager: TerminalTabManager) {
        manager.sessionState.install(tab, paneState: TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        ), select: true)
        manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Denied",
            host: "example.invalid",
            username: "test"
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }
}
