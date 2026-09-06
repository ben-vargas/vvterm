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

@MainActor
private final class EternalTerminalOwnerState {
    var isCurrent = true
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

private actor EternalTerminalSendGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async -> Bool {
        for _ in 0..<2_000 {
            if continuation != nil { return true }
            await Task.yield()
        }
        return continuation != nil
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TestEternalTerminalSession: EternalTerminalSession {
    nonisolated let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation
    nonisolated let stateChanges: AsyncStream<EternalTerminalSessionState>

    private let stateContinuation: AsyncStream<EternalTerminalSessionState>.Continuation
    private let connectGate: EternalTerminalConnectGate?
    private let sendGate: EternalTerminalSendGate?
    private let sendFailure: EternalTerminalSessionFailure?
    private let stateBeforeSendReturns: EternalTerminalSessionState?
    private let startupPlan: TerminalShellStartupPlan
    private var closeCalls = 0
    private var commandWasSent = false
    private var sendAttempts = 0

    init(
        connectGate: EternalTerminalConnectGate? = nil,
        sendGate: EternalTerminalSendGate? = nil,
        sendFailure: EternalTerminalSessionFailure? = nil,
        stateBeforeSendReturns: EternalTerminalSessionState? = nil,
        startupPlan: TerminalShellStartupPlan = .plainShell
    ) {
        let outputStream = AsyncStream.makeStream(of: Data.self)
        output = outputStream.stream
        outputContinuation = outputStream.continuation
        let stream = AsyncStream.makeStream(of: EternalTerminalSessionState.self)
        stateChanges = stream.stream
        stateContinuation = stream.continuation
        self.connectGate = connectGate
        self.sendGate = sendGate
        self.sendFailure = sendFailure
        self.stateBeforeSendReturns = stateBeforeSendReturns
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
        sendAttempts += 1
        if let sendGate {
            await sendGate.wait()
        }
        if let stateBeforeSendReturns {
            stateContinuation.yield(stateBeforeSendReturns)
        }
        if let sendFailure {
            throw sendFailure
        }
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

    func waitUntilSendIsAttempted() async -> Bool {
        for _ in 0..<2_000 {
            if sendAttempts > 0 { return true }
            await Task.yield()
        }
        return sendAttempts > 0
    }

    func sendAttemptCount() -> Int { sendAttempts }

    func emit(_ state: EternalTerminalSessionState) {
        if state == .sessionEnded { outputContinuation.finish() }
        stateContinuation.yield(state)
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
    private(set) var discardedPaneIDs: [UUID] = []

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

    func discardResumeState(for paneId: UUID) throws { discardedPaneIDs.append(paneId) }
}

@Suite(.serialized)
@MainActor
struct EternalTerminalRuntimeDependencyIsolationTests {
    @Test(arguments: [true, false])
    func endedSessionClearsResumeStateOnlyForCurrentOwner(isCurrent: Bool) async {
        let ownerState = EternalTerminalOwnerState()
        ownerState.isCurrent = isCurrent
        let session = TestEternalTerminalSession()
        let preparer = SequencedEternalTerminalSessionPreparer(sessions: [session])
        var endReasons: [TerminalShellEndReason] = []
        let runtime = makeRuntime(
            dependencies: EternalTerminalRuntimeDependencies(
                recordEvent: { _ in },
                remoteSessionKiller: EternalTerminalRemoteSessionKillRecorder(),
                sessionPreparer: preparer
            ),
            ownerState: ownerState,
            handleShellEnd: { _, _, reason in endReasons.append(reason) }
        )
        runtime.resize(cols: 80, rows: 24, pixelSize: nil)
        runtime.startIfNeeded()
        await session.emit(.sessionEnded)
        for _ in 0..<2_000 {
            if !endReasons.isEmpty { break }
            await Task.yield()
        }
        #expect(endReasons == (isCurrent ? [.sessionEnded] : []))
        #expect(preparer.discardedPaneIDs.count == (isCurrent ? 1 : 0))
        await runtime.close()
    }

    @Test(arguments: [EternalTerminalSessionState.closed, .sessionEnded])
    func closedStandaloneActionPublishesItsTerminalEndReason(state: EternalTerminalSessionState) async {
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

        await session.emit(state)

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
    func rejectedStartupSendClearsReplayGuardAndResumeContext() async throws {
        let plan = try managedStartupPlan()
        let session = TestEternalTerminalSession(
            sendFailure: .connectionClosed,
            startupPlan: plan
        )
        var replayGuardStates: [Bool] = []
        var resumeContexts: [RemoteSessionLifecycleContext?] = []
        let runtime = makeRuntime(
            dependencies: EternalTerminalRuntimeDependencies(
                recordEvent: { _ in },
                remoteSessionKiller: EternalTerminalRemoteSessionKillRecorder(),
                sessionPreparer: SequencedEternalTerminalSessionPreparer(
                    sessions: [session]
                )
            ),
            setResumeContext: { _, context in
                resumeContexts.append(context)
            },
            setStartupActionReplayGuard: { _, isPending in
                replayGuardStates.append(isPending)
            }
        )

        runtime.resize(cols: 80, rows: 24, pixelSize: nil)
        runtime.startIfNeeded()
        #expect(await session.waitUntilSendIsAttempted())
        for _ in 0..<2_000 {
            if replayGuardStates == [true, false] { break }
            await Task.yield()
        }

        #expect(replayGuardStates == [true, false])
        #expect(resumeContexts.count == 2)
        if resumeContexts.count == 2 {
            #expect(resumeContexts[0] == plan.remoteSessionLifecycle)
            #expect(resumeContexts[1] == nil)
        }
        await runtime.close()
    }

    @Test
    func disconnectedReliableSendAcceptanceKeepsReplayGuard() async {
        let session = TestEternalTerminalSession(
            stateBeforeSendReturns: .disconnected,
            startupPlan: TerminalShellStartupPlan(
                command: "notify-deployment",
                remoteSessionLifecycle: nil,
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
    func transportFailureAfterReliableAcceptanceKeepsReplayGuard() async {
        let session = TestEternalTerminalSession(
            startupPlan: TerminalShellStartupPlan(
                command: "notify-deployment",
                remoteSessionLifecycle: nil,
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
        await session.emit(.failed(.transport))
        for _ in 0..<20 { await Task.yield() }

        #expect(replayGuardStates == [true])
        await runtime.close()
    }

    @Test
    func resumedSessionDoesNotSendStartupCommandAgain() async {
        let session = TestEternalTerminalSession(
            startupPlan: TerminalShellStartupPlan(
                command: "notify-deployment",
                remoteSessionLifecycle: nil,
                mayExecuteUserStartupAction: true
            )
        )
        let runtime = makeRuntime(
            dependencies: EternalTerminalRuntimeDependencies(
                recordEvent: { _ in },
                remoteSessionKiller: EternalTerminalRemoteSessionKillRecorder(),
                sessionPreparer: SequencedEternalTerminalSessionPreparer(
                    sessions: [session],
                    origin: .resumed
                )
            ),
            resumedStandaloneAction: true
        )

        runtime.resize(cols: 80, rows: 24, pixelSize: nil)
        runtime.startIfNeeded()
        for _ in 0..<2_000 {
            if !runtime.isStartInFlight { break }
            await Task.yield()
        }

        #expect(await session.sendAttemptCount() == 0)
        await runtime.close()
    }

    @Test
    func staleRuntimeCannotClearCurrentReplayGuardAfterSendRejection() async {
        let ownerState = EternalTerminalOwnerState()
        let sendGate = EternalTerminalSendGate()
        let session = TestEternalTerminalSession(
            sendGate: sendGate,
            sendFailure: .connectionClosed,
            startupPlan: TerminalShellStartupPlan(
                command: "notify-deployment",
                remoteSessionLifecycle: nil,
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
            ownerState: ownerState,
            setStartupActionReplayGuard: { _, isPending in
                replayGuardStates.append(isPending)
            }
        )

        runtime.resize(cols: 80, rows: 24, pixelSize: nil)
        runtime.startIfNeeded()
        #expect(await sendGate.waitUntilBlocked())
        #expect(replayGuardStates == [true])
        ownerState.isCurrent = false
        await sendGate.release()
        for _ in 0..<20 { await Task.yield() }

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
        ownerState: EternalTerminalOwnerState? = nil,
        resumeContext: RemoteSessionLifecycleContext? = nil,
        setResumeContext: @MainActor @Sendable @escaping (
            UUID,
            RemoteSessionLifecycleContext?
        ) -> Void = { _, _ in },
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
                isCurrent: { _, _ in ownerState?.isCurrent ?? true },
                startupPlan: { _, _, _, _ in throw CancellationError() },
                resumeContext: { _ in resumeContext },
                setResumeContext: setResumeContext,
                startupActionReplayPending: { _ in
                    resumedStandaloneAction
                },
                setStartupActionReplayPending: setStartupActionReplayGuard,
                remoteSessionAttached: { _ in },
                updateConnectionState: { _, _ in },
                markEternalTerminalTransport: { _ in },
                handleShellEnd: handleShellEnd,
                unregister: { _, _ in }
            ),
            dependencies: dependencies
        )
    }

    private func managedStartupPlan() throws -> TerminalShellStartupPlan {
        let lifecycle = try RemoteSessionLifecycleContext(
            attachment: RemoteSessionAttachment(
                identifier: RemoteSessionIdentifier(
                    backendIdentifier: .tmux,
                    validating: "vvterm-managed"
                ),
                ownership: .managed
            ),
            legacyTmuxMarkerToken: "marker-token"
        )
        return TerminalShellStartupPlan(
            command: "create-managed-session",
            remoteSessionLifecycle: lifecycle,
            mayExecuteUserStartupAction: true
        )
    }
}
