import Combine
import ETSession
import Foundation
import MoshCore
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

private final class DependencyTestMoshResumeStore: MoshResumeStoring {
    func snapshot(for paneId: UUID) throws -> MoshSnapshot? { nil }
    func hasSnapshot(for paneId: UUID) -> Bool { false }
    func save(_ snapshot: MoshSnapshot, for paneId: UUID) throws {}
    func deleteSnapshot(for paneId: UUID) throws {}
}

@MainActor
private final class TerminalEffectRecorder {
    var authorizeResult = true
    private(set) var authorizationRequests: [UUID] = []
    private(set) var liveActivityRefreshCount = 0
    private(set) var successfulConnections: [(UUID, String)] = []
    private(set) var sessionEndStates: [Bool] = []
    private(set) var splitPaneCount = 0

    func effects() -> TerminalSessionApplicationEffects {
        TerminalSessionApplicationEffects(
            authorizeServer: { [self] server in
                authorizationRequests.append(server.id)
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

private actor RecordingTerminalRemoteTmuxService: TerminalRemoteTmuxServicing {
    private var killedSessions: [String] = []

    func killedSessionNames() -> [String] {
        killedSessions
    }

    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability {
        .unsupported
    }

    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        nil
    }

    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async throws -> [RemoteTmuxSession] {
        []
    }

    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend?
    ) async {}

    func sendScript(
        _ script: String,
        using client: SSHClient,
        shellId: UUID
    ) async throws {}

    func killSession(
        named sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {
        killedSessions.append(sessionName)
    }

    func cleanupLegacySessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {}

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {}

    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
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
            remoteTmux: firstTmux,
            remoteMosh: firstMosh,
            deviceID: "first-device"
        )
        let second = makeManager(
            network: secondNetwork,
            effects: secondEffects,
            remoteTmux: secondTmux,
            remoteMosh: secondMosh,
            deviceID: "second-device"
        )

        firstNetwork.send(.ready)
        #expect(first.currentNetworkReadiness == .ready)
        #expect(second.currentNetworkReadiness == .unknown)

        firstEffects.authorizeResult = false
        do {
            _ = try await first.openTab(for: makeServer())
            Issue.record("The injected access denial should stop the tab open")
        } catch {
            #expect(firstEffects.authorizationRequests.count == 1)
        }
        #expect(first.serverIdsWithTabs().isEmpty)
        #expect(secondEffects.authorizationRequests.isEmpty)

        let tab = TerminalTab(serverId: UUID(), title: "First manager")
        install(tab, in: first)
        #expect(first.splitRight(
            tab: tab,
            paneId: tab.rootPaneId,
            hasProAccess: true
        ) != nil)
        first.updatePaneState(tab.rootPaneId, connectionState: .connected)

        let client = SSHClient()
        let startToken = try #require(
            first.beginShellStart(for: tab.rootPaneId, client: client)
        )
        #expect(await first.registerSSHClient(
            client,
            shellId: UUID(),
            startToken: startToken,
            for: tab.rootPaneId,
            serverId: tab.serverId
        ))
        first.tmuxResolver.sessionNames[tab.rootPaneId] = "first-session"
        first.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed

        try await first.installMoshServer(for: tab.rootPaneId)
        first.killTmuxIfNeeded(for: tab.rootPaneId)
        #expect(await waitUntil {
            await firstTmux.killedSessionNames() == ["first-session"]
        })
        await first.unregisterSSHClient(for: tab.rootPaneId)
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
        #expect(await secondTmux.killedSessionNames().isEmpty)
        #expect(
            first.tmuxResolver.managedSessionName(for: tab.rootPaneId)
                != second.tmuxResolver.managedSessionName(for: tab.rootPaneId)
        )

        await first.resetForTesting()
        await second.resetForTesting()
    }

    private func makeManager(
        network: PassthroughSubject<TerminalNetworkReadiness, Never>,
        effects: TerminalEffectRecorder,
        remoteTmux: RecordingTerminalRemoteTmuxService,
        remoteMosh: RecordingTerminalRemoteMoshService,
        deviceID: String
    ) -> TerminalTabManager {
        TerminalTabManager(
            snapshotStore: DependencyTestSnapshotStore(),
            dependencies: TerminalTabManagerDependencies(
                networkReadiness: TerminalNetworkReadinessSource(
                    initial: .unknown,
                    updates: network.eraseToAnyPublisher()
                ),
                applicationIsActive: { true },
                effects: effects.effects(),
                tmuxConfiguration: TerminalTmuxConfiguration(
                    deviceID: deviceID,
                    enabledByDefault: { false },
                    startupBehaviorByDefault: { .skipTmux },
                    serverSettings: { _ in nil },
                    themeStyle: {
                        TerminalTabManager.remoteTmuxThemeStyle(for: nil)
                    }
                ),
                remoteTmux: remoteTmux,
                remoteMosh: remoteMosh,
                eternalTerminalRuntime: .testing
            ),
            eternalTerminalResumeStore: DependencyTestETResumeStore(),
            moshResumeStore: DependencyTestMoshResumeStore()
        )
    }

    private func install(_ tab: TerminalTab, in manager: TerminalTabManager) {
        manager.installTabForTesting(tab, paneState: TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        ))
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
