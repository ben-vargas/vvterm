import ETSession
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class EternalTerminalDependencySnapshotStore: TerminalTabSnapshotStoring {
    private var data: Data?

    func loadSnapshotData() -> Data? { data }
    func saveSnapshotData(_ data: Data) { self.data = data }
    func removeSnapshotData() { data = nil }
}

@MainActor
private final class EternalTerminalEventRecorder {
    private(set) var events: [EternalTerminalRuntimeEvent] = []

    func record(_ event: EternalTerminalRuntimeEvent) {
        events.append(event)
    }
}

private actor EternalTerminalTmuxKillRecorder: EternalTerminalTmuxSessionKilling {
    private var sessionNames: [String] = []

    func killSession(named sessionName: String, using client: SSHClient) async {
        sessionNames.append(sessionName)
    }

    func recordedSessionNames() -> [String] {
        sessionNames
    }
}

private final class FailingEternalTerminalResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? {
        throw EternalTerminalResumeCredentialError.secureStorageUnavailable
    }

    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { false }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

@MainActor
private struct FailingEternalTerminalSessionPreparer: EternalTerminalSessionPreparing {
    func prepareSession(
        request: EternalTerminalSessionRequest,
        startupPlanProvider: @Sendable @escaping (SSHClient) async throws -> TerminalShellStartupPlan,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws -> PreparedEternalTerminalSession {
        throw EternalTerminalSessionFailure.resumeState(
            message: "Unavailable test session",
            discardStoredState: false
        )
    }

    func discardResumeState(for paneId: UUID) throws {}
}

@Suite(.serialized)
@MainActor
struct EternalTerminalRuntimeDependencyIsolationTests {
    @Test
    func runtimesAndPortsKeepEffectsAndTmuxKillsWithTheirOwners() async {
        let firstEvents = EternalTerminalEventRecorder()
        let secondEvents = EternalTerminalEventRecorder()
        let firstTmux = EternalTerminalTmuxKillRecorder()
        let secondTmux = EternalTerminalTmuxKillRecorder()
        let firstDependencies = dependencies(events: firstEvents, tmux: firstTmux)
        let secondDependencies = dependencies(events: secondEvents, tmux: secondTmux)
        let firstManager = makeManager()
        let secondManager = makeManager()
        let firstRuntime = makeRuntime(
            manager: firstManager,
            dependencies: firstDependencies
        )
        let secondRuntime = makeRuntime(
            manager: secondManager,
            dependencies: secondDependencies
        )

        firstRuntime.startIfNeeded()
        firstRuntime.abortConnection()
        firstDependencies.record(.connectionReconnecting)
        firstDependencies.record(.connectionFailed(reason: "network"))
        await firstDependencies.killTmuxSession(
            named: "first-session",
            using: SSHClient()
        )

        #expect(firstEvents.events == [
            .connectionAttempted,
            .connectionReconnecting,
            .connectionFailed(reason: "network")
        ])
        #expect(secondEvents.events.isEmpty)
        #expect(await firstTmux.recordedSessionNames() == ["first-session"])
        #expect(await secondTmux.recordedSessionNames().isEmpty)

        await firstRuntime.close()
        await secondRuntime.close()
        await firstManager.resetForTesting()
        await secondManager.resetForTesting()
    }

    private func dependencies(
        events: EternalTerminalEventRecorder,
        tmux: EternalTerminalTmuxKillRecorder
    ) -> EternalTerminalRuntimeDependencies {
        EternalTerminalRuntimeDependencies(
            recordEvent: { [events] event in
                events.record(event)
            },
            tmuxSessionKiller: tmux,
            sessionPreparer: FailingEternalTerminalSessionPreparer()
        )
    }

    private func makeRuntime(
        manager: TerminalTabManager,
        dependencies: EternalTerminalRuntimeDependencies
    ) -> EternalTerminalRuntime {
        let server = Server(
            workspaceId: UUID(),
            name: "Isolated ET",
            host: "example.invalid",
            username: "test"
        )
        return EternalTerminalRuntime(
            paneId: UUID(),
            server: server,
            credentials: ServerCredentials(serverId: server.id),
            tabManager: manager,
            dependencies: dependencies
        )
    }

    private func makeManager() -> TerminalTabManager {
        TerminalTabManager(
            snapshotStore: EternalTerminalDependencySnapshotStore(),
            networkReadinessPublisher: nil,
            liveActivityRefresh: { _ in },
            tmuxCoordinator: TerminalTmuxSessionCoordinator(),
            terminalSurfaceStore: GhosttyTerminalSurfaceStore(),
            eternalTerminalResumeStore: FailingEternalTerminalResumeStore(),
            moshRecovery: UnavailableTerminalMoshRecoveryService()
        )
    }
}
