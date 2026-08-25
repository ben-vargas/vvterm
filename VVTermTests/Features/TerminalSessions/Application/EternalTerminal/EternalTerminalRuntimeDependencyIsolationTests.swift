import ETSession
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class EternalTerminalEventRecorder {
    private(set) var events: [EternalTerminalRuntimeEvent] = []

    func record(_ event: EternalTerminalRuntimeEvent) {
        events.append(event)
    }
}

private actor EternalTerminalRemoteSessionKillRecorder: EternalTerminalRemoteSessionKilling {
    private var identifiers: [RemoteSessionIdentifier] = []

    func killSession(_ identifier: RemoteSessionIdentifier, using client: SSHClient) async {
        identifiers.append(identifier)
    }

    func recordedIdentifiers() -> [RemoteSessionIdentifier] {
        identifiers
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

private actor EternalTerminalConnectGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func waitIgnoringCancellation() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if continuations.count >= count { return true }
            await Task.yield()
        }
        return continuations.count >= count
    }

    func release(at index: Int) {
        continuations[index].resume()
    }
}

private actor TestEternalTerminalSession: EternalTerminalSession {
    nonisolated let output = AsyncStream<Data> { _ in }
    nonisolated let stateChanges: AsyncStream<EternalTerminalSessionState>

    private let stateContinuation: AsyncStream<EternalTerminalSessionState>.Continuation
    private let connectGate: EternalTerminalConnectGate?
    private let startupPlan: TerminalShellStartupPlan
    private var closeCalls = 0
    private var commandWasSent = false

    init(
        connectGate: EternalTerminalConnectGate? = nil,
        startupPlan: TerminalShellStartupPlan = .plainShell
    ) {
        let stream = AsyncStream.makeStream(of: EternalTerminalSessionState.self)
        stateChanges = stream.stream
        stateContinuation = stream.continuation
        self.connectGate = connectGate
        self.startupPlan = startupPlan
    }

    func connect() async throws {
        if let connectGate {
            await connectGate.waitIgnoringCancellation()
        } else {
            stateContinuation.yield(.connected)
        }
    }

    func send(_ data: Data) async throws {
        commandWasSent = true
    }

    func resize(
        rows: Int,
        cols: Int,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) async throws {}

    func notifyNetworkPathChanged() async {}

    func persistCheckpoint(
        ifCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws {}

    func prepareForApplicationBackground(
        ifCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws {}

    func resumeFromApplicationBackground() async {}
    func preparedStartupPlan() async -> TerminalShellStartupPlan { startupPlan }

    func withBootstrapSSHClient<Result: Sendable>(
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        try await operation(SSHClient.testing())
    }

    func close() async {
        closeCalls += 1
    }

    func closeCount() -> Int { closeCalls }

    func waitUntilCommandIsSent() async -> Bool {
        for _ in 0..<2_000 {
            if commandWasSent { return true }
            await Task.yield()
        }
        return commandWasSent
    }

    func finish() {
        stateContinuation.yield(.closed)
    }
}

@MainActor
private final class SequencedEternalTerminalSessionPreparer: EternalTerminalSessionPreparing {
    private let sessions: [TestEternalTerminalSession]
    private let origin: EternalTerminalSessionOrigin
    private var nextIndex = 0

    init(
        sessions: [TestEternalTerminalSession],
        origin: EternalTerminalSessionOrigin = .bootstrapped
    ) {
        self.sessions = sessions
        self.origin = origin
    }

    func prepareSession(
        request: EternalTerminalSessionRequest,
        startupPlanProvider: @Sendable @escaping (SSHClient) async throws -> TerminalShellStartupPlan,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws -> PreparedEternalTerminalSession {
        guard sessions.indices.contains(nextIndex) else { throw CancellationError() }
        let session = sessions[nextIndex]
        nextIndex += 1
        return PreparedEternalTerminalSession(session: session, origin: origin)
    }

    func discardResumeState(for paneId: UUID) throws {}
}

@Suite(.serialized)
@MainActor
struct EternalTerminalRuntimeDependencyIsolationTests {
    @Test
    func closedStandaloneActionPublishesItsTerminalEndReason() async {
        let session = TestEternalTerminalSession(
            startupPlan: TerminalShellStartupPlan(
                command: "exec /bin/sh -lc 'printf done'",
                remoteSessionLifecycle: nil,
                mayExecuteUserStartupAction: true
            )
        )
        var endReasons: [TerminalShellEndReason] = []
        let dependencies = EternalTerminalRuntimeDependencies(
            recordEvent: { _ in },
            remoteSessionKiller: EternalTerminalRemoteSessionKillRecorder(),
            sessionPreparer: SequencedEternalTerminalSessionPreparer(
                sessions: [session]
            )
        )
        let runtime = makeRuntime(
            dependencies: dependencies,
            handleShellEnd: { _, _, reason in
                endReasons.append(reason)
            }
        )

        runtime.resize(cols: 80, rows: 24, pixelSize: nil)
        runtime.startIfNeeded()
        #expect(await session.waitUntilCommandIsSent())

        await session.finish()

        for _ in 0..<2_000 {
            if !endReasons.isEmpty { break }
            await Task.yield()
        }
        #expect(endReasons == [.standaloneStartupActionCompleted])
        await runtime.close()
    }

    @Test
    func managedActionSetsReplayGuardBeforeSending() async throws {
        let lifecycle = try RemoteSessionLifecycleContext(
            attachment: RemoteSessionAttachment(
                identifier: try RemoteSessionIdentifier(
                    backendIdentifier: .tmux,
                    validating: "vvterm-managed"
                ),
                ownership: .managed
            ),
            legacyTmuxMarkerToken: "marker-token"
        )
        let session = TestEternalTerminalSession(
            startupPlan: TerminalShellStartupPlan(
                command: "create-managed-session",
                remoteSessionLifecycle: lifecycle,
                mayExecuteUserStartupAction: true
            )
        )
        var replayGuardStates: [Bool] = []
        let runtime = makeRuntime(
            dependencies: EternalTerminalRuntimeDependencies(
                recordEvent: { _ in },
                remoteSessionKiller: EternalTerminalRemoteSessionKillRecorder(),
                sessionPreparer: SequencedEternalTerminalSessionPreparer(
                    sessions: [session]
                )
            ),
            setStartupActionReplayGuard: { _, isPending in
                replayGuardStates.append(isPending)
            }
        )

        runtime.resize(cols: 80, rows: 24, pixelSize: nil)
        runtime.startIfNeeded()
        #expect(await session.waitUntilCommandIsSent())
        #expect(replayGuardStates == [true])
        await runtime.close()
    }

    @Test
    func resumedStandaloneActionKeepsItsOneTimeCompletionState() async {
        let session = TestEternalTerminalSession()
        var endReasons: [TerminalShellEndReason] = []
        let dependencies = EternalTerminalRuntimeDependencies(
            recordEvent: { _ in },
            remoteSessionKiller: EternalTerminalRemoteSessionKillRecorder(),
            sessionPreparer: SequencedEternalTerminalSessionPreparer(
                sessions: [session],
                origin: .resumed
            )
        )
        let runtime = makeRuntime(
            dependencies: dependencies,
            resumedStandaloneAction: true,
            handleShellEnd: { _, _, reason in
                endReasons.append(reason)
            }
        )

        runtime.resize(cols: 80, rows: 24, pixelSize: nil)
        runtime.startIfNeeded()
        for _ in 0..<2_000 {
            if !runtime.isStartInFlight { break }
            await Task.yield()
        }
        await session.finish()
        for _ in 0..<2_000 {
            if !endReasons.isEmpty { break }
            await Task.yield()
        }

        #expect(endReasons == [.standaloneStartupActionCompleted])
        await runtime.close()
    }

    @Test
    func cancelledConnectCannotClearReplacementOrCloseAnAcceptedSessionTwice() async {
        let gate = EternalTerminalConnectGate()
        let firstSession = TestEternalTerminalSession(connectGate: gate)
        let replacementSession = TestEternalTerminalSession(connectGate: gate)
        let events = EternalTerminalEventRecorder()
        let dependencies = EternalTerminalRuntimeDependencies(
            recordEvent: { [events] event in events.record(event) },
            remoteSessionKiller: EternalTerminalRemoteSessionKillRecorder(),
            sessionPreparer: SequencedEternalTerminalSessionPreparer(
                sessions: [firstSession, replacementSession]
            )
        )
        let runtime = makeRuntime(dependencies: dependencies)

        runtime.startIfNeeded()
        #expect(await gate.waitForCount(1))
        runtime.abortConnection()
        runtime.startIfNeeded()
        #expect(await gate.waitForCount(2))

        await gate.release(at: 0)
        for _ in 0..<20 { await Task.yield() }

        #expect(runtime.isStartInFlight)
        #expect(await firstSession.closeCount() == 1)

        await runtime.close()
        await gate.release(at: 1)
        for _ in 0..<20 { await Task.yield() }

        #expect(await firstSession.closeCount() == 1)
        #expect(await replacementSession.closeCount() == 1)
    }

    @Test
    func runtimesAndPortsKeepEffectsAndRemoteSessionKillsWithTheirOwners() async {
        let firstEvents = EternalTerminalEventRecorder()
        let secondEvents = EternalTerminalEventRecorder()
        let firstSessions = EternalTerminalRemoteSessionKillRecorder()
        let secondSessions = EternalTerminalRemoteSessionKillRecorder()
        let firstDependencies = dependencies(events: firstEvents, sessions: firstSessions)
        let secondDependencies = dependencies(events: secondEvents, sessions: secondSessions)
        let firstRuntime = makeRuntime(
            dependencies: firstDependencies
        )
        let secondRuntime = makeRuntime(
            dependencies: secondDependencies
        )

        firstRuntime.startIfNeeded()
        firstRuntime.abortConnection()
        firstDependencies.record(.connectionReconnecting)
        firstDependencies.record(.connectionFailed(reason: "network"))
        let identifier = try! RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "first-session"
        )
        await firstDependencies.killRemoteSession(
            identifier,
            using: SSHClient.testing()
        )

        #expect(firstEvents.events == [
            .connectionAttempted,
            .connectionReconnecting,
            .connectionFailed(reason: "network")
        ])
        #expect(secondEvents.events.isEmpty)
        #expect(await firstSessions.recordedIdentifiers() == [identifier])
        #expect(await secondSessions.recordedIdentifiers().isEmpty)

        await firstRuntime.close()
        await secondRuntime.close()
    }

    private func dependencies(
        events: EternalTerminalEventRecorder,
        sessions: EternalTerminalRemoteSessionKillRecorder
    ) -> EternalTerminalRuntimeDependencies {
        EternalTerminalRuntimeDependencies(
            recordEvent: { [events] event in
                events.record(event)
            },
            remoteSessionKiller: sessions,
            sessionPreparer: FailingEternalTerminalSessionPreparer()
        )
    }

    private func makeRuntime(
        dependencies: EternalTerminalRuntimeDependencies,
        resumedStandaloneAction: Bool = false,
        setStartupActionReplayGuard: @MainActor @Sendable @escaping (
            UUID,
            Bool
        ) -> Void = { _, _ in },
        handleShellEnd: @MainActor @Sendable @escaping (
            UUID,
            UUID,
            TerminalShellEndReason
        ) -> Void = { _, _, _ in }
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
            ownerAccess: EternalTerminalRuntimeOwnerAccess(
                isCurrent: { _, _ in true },
                startupPlan: { _, _, _, _ in throw CancellationError() },
                resumeContext: { _ in nil },
                setResumeContext: { _, _ in },
                standaloneStartupActionPendingCompletion: { _ in
                    resumedStandaloneAction
                },
                setStandaloneStartupActionPendingCompletion: setStartupActionReplayGuard,
                remoteSessionAttached: { _ in },
                updateConnectionState: { _, _ in },
                markEternalTerminalTransport: { _ in },
                handleShellEnd: handleShellEnd,
                unregister: { _, _ in }
            ),
            dependencies: dependencies
        )
    }
}
