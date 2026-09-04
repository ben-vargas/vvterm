import Foundation
import os.log
import Testing
@testable import VVTerm

private actor SSHConnectionRunnerTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async -> Bool {
        for _ in 0..<100_000 {
            if continuation != nil { return true }
            await Task.yield()
        }
        return continuation != nil
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SSHConnectionRunnerTestRecorder {
    private var closeShellIds: [UUID] = []
    private var registrationCount = 0
    private var startSizes: [(columns: Int, rows: Int)] = []

    func recordClose(shellId: UUID) {
        closeShellIds.append(shellId)
    }

    func recordRegistration() {
        registrationCount += 1
    }

    func recordStart(columns: Int, rows: Int) {
        startSizes.append((columns, rows))
    }

    func closeCount(for shellId: UUID) -> Int {
        closeShellIds.reduce(into: 0) { count, closedShellId in
            if closedShellId == shellId {
                count += 1
            }
        }
    }

    func registrations() -> Int {
        registrationCount
    }

    func recordedStartSizes() -> [[Int]] {
        startSizes.map { [$0.columns, $0.rows] }
    }
}

@MainActor
private final class SSHConnectionRunnerPendingStateRecorder {
    private(set) var states: [Bool] = []

    func record(_ isPending: Bool) {
        states.append(isPending)
    }
}

enum SSHConnectionRunnerPreDispatchFailure: CaseIterable, Sendable {
    case channelOpen
    case disconnected
    case ptyRequest
    case processRequestDenied

    var error: SSHError {
        switch self {
        case .channelOpen: .channelOpenFailed
        case .disconnected: .disconnectedBeforeShellRequest
        case .ptyRequest: .ptyRequestFailed
        case .processRequestDenied: .processRequestDenied
        }
    }
}

@Suite(.serialized)
@MainActor
struct SSHConnectionRunnerTests {
    @Test
    func scriptPreparationFailureAllowsManualRetryWithoutReplayingAnAction() async {
        let fixture = makeFixture()
        let pending = SSHConnectionRunnerPendingStateRecorder()
        var attempts: [Int] = []
        var reportedPreparationFailure = false
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { _, _, _, _, _, profile in
                #expect(profile?.family == .powershell)
                throw SSHShellPreparationError(underlying: SFTPTransportError.invalidEntryName)
            },
            disconnect: {}, closeShell: { _ in }, execute: { _, _ in "" }
        )
        await SSHConnectionRunner.run(
            server: fixture.server, credentials: fixture.credentials, transport: transport,
            initialTerminalState: .init(columns: 80, rows: 24, pixelSize: nil),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true }, onAttempt: { attempts.append($0) },
            startupPlan: {
                TerminalShellStartupPlan(
                    command: "notify-deployment", remoteSessionLifecycle: nil,
                    mayExecuteUserStartupAction: true,
                    shellProfile: .powershell(executableName: "powershell.exe")
                )
            },
            setStartupActionReplayGuard: pending.record,
            restoreMoshShell: { _, _ in nil }, registerShell: { _, _ in true },
            onTitleChange: { _ in }, writeOutput: { _ in true }, shouldResetClient: { _ in false },
            onProcessExit: { _, _ in },
            onFailure: { reportedPreparationFailure = $0 is SSHShellPreparationError }
        )
        #expect(attempts == [1])
        #expect(pending.states == [true, false])
        #expect(reportedPreparationFailure)
        #expect(!TerminalConnectionFailure.transport(
            SSHShellPreparationError(underlying: SFTPTransportError.invalidEntryName)
        ).allowsAutomaticReconnectRetry)
        #expect(!TerminalConnectionFailure.transport(
            SSHCommandExitError(exitStatus: 1)
        ).allowsAutomaticReconnectRetry)
    }

    @Test
    func plainStartupActionFailureStopsConnectionAttempts() async {
        let fixture = makeFixture()
        let recorder = SSHConnectionRunnerTestRecorder()
        let startupCommand = "notify-deployment"
        var attempts: [Int] = []
        var reportedFailure: SSHError?
        let pendingStateRecorder = SSHConnectionRunnerPendingStateRecorder()
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { columns, rows, _, command, mayExecuteUserStartupAction, _ in
                #expect(command == startupCommand)
                #expect(mayExecuteUserStartupAction)
                await recorder.recordStart(columns: columns, rows: rows)
                throw SSHError.notConnected
            },
            disconnect: {},
            closeShell: { _ in },
            execute: { _, _ in "" }
        )

        await SSHConnectionRunner.run(
            server: fixture.server,
            credentials: fixture.credentials,
            transport: transport,
            initialTerminalState: SSHConnectionInitialTerminalState(
                columns: 132,
                rows: 43,
                pixelSize: nil
            ),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true },
            onAttempt: { attempts.append($0) },
            startupPlan: {
                TerminalShellStartupPlan(
                    command: startupCommand,
                    remoteSessionLifecycle: nil,
                    mayExecuteUserStartupAction: true
                )
            },
            setStartupActionReplayGuard: pendingStateRecorder.record,
            restoreMoshShell: { _, _ in nil },
            registerShell: { _, _ in true },
            onTitleChange: { _ in },
            writeOutput: { _ in true },
            shouldResetClient: { _ in false },
            onProcessExit: { _, _ in },
            onFailure: { error in
                reportedFailure = error as? SSHError
            }
        )

        #expect(attempts == [1])
        #expect(await recorder.recordedStartSizes() == [[132, 43]])
        #expect(pendingStateRecorder.states == [true])
        guard case .startupCommandMayHaveRun = reportedFailure else {
            Issue.record("Expected the possible command execution failure")
            return
        }
    }

    @Test(arguments: SSHConnectionRunnerPreDispatchFailure.allCases)
    func preDispatchFailureClearsReplayGuardAndRetriesOnlyTransientErrors(
        _ failure: SSHConnectionRunnerPreDispatchFailure
    ) async {
        let fixture = makeFixture()
        let recorder = SSHConnectionRunnerTestRecorder()
        let pendingStateRecorder = SSHConnectionRunnerPendingStateRecorder()
        var attempts: [Int] = []
        var reportedFailure: SSHError?
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { columns, rows, _, _, mayExecuteUserStartupAction, _ in
                #expect(mayExecuteUserStartupAction)
                await recorder.recordStart(columns: columns, rows: rows)
                throw failure.error
            },
            disconnect: {},
            closeShell: { _ in },
            execute: { _, _ in "" }
        )

        await SSHConnectionRunner.run(
            server: fixture.server,
            credentials: fixture.credentials,
            transport: transport,
            initialTerminalState: SSHConnectionInitialTerminalState(
                columns: 132,
                rows: 43,
                pixelSize: nil
            ),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true },
            onAttempt: { attempts.append($0) },
            startupPlan: {
                TerminalShellStartupPlan(
                    command: "notify-deployment",
                    remoteSessionLifecycle: nil,
                    mayExecuteUserStartupAction: true
                )
            },
            setStartupActionReplayGuard: pendingStateRecorder.record,
            restoreMoshShell: { _, _ in nil },
            registerShell: { _, _ in true },
            onTitleChange: { _ in },
            writeOutput: { _ in true },
            shouldResetClient: { _ in false },
            onProcessExit: { _, _ in },
            onFailure: { error in reportedFailure = error as? SSHError }
        )

        let attemptCount = failure == .processRequestDenied ? 1 : 3
        #expect(attempts == Array(1...attemptCount))
        #expect(await recorder.recordedStartSizes() == Array(repeating: [132, 43], count: attemptCount))
        #expect(pendingStateRecorder.states == (0..<attemptCount).flatMap { _ in [true, false] })
        switch failure {
        case .channelOpen:
            guard case .channelOpenFailed = reportedFailure else {
                Issue.record("Expected the pre-dispatch channel-open failure")
                return
            }
        case .disconnected:
            guard case .disconnectedBeforeShellRequest = reportedFailure else {
                Issue.record("Expected the pre-dispatch disconnect")
                return
            }
        case .ptyRequest:
            guard case .ptyRequestFailed = reportedFailure else {
                Issue.record("Expected the pre-dispatch PTY failure")
                return
            }
        case .processRequestDenied:
            guard case .processRequestDenied = reportedFailure else {
                Issue.record("Expected the explicit process-request denial")
                return
            }
        }
    }

    @Test(arguments: [false, true])
    func broadShellRequestFailureDoesNotClearOrReplayStartupAction(
        _ usesPersistentSession: Bool
    ) async throws {
        let fixture = makeFixture()
        let pendingStateRecorder = SSHConnectionRunnerPendingStateRecorder()
        var attempts: [Int] = []
        var reportedFailure: SSHError?
        let lifecycle: RemoteSessionLifecycleContext? = if usesPersistentSession {
            try RemoteSessionLifecycleContext(
                attachment: RemoteSessionAttachment(
                    identifier: RemoteSessionIdentifier(
                        backendIdentifier: .tmux,
                        validating: "vvterm-managed"
                    ),
                    ownership: .managed
                ),
                legacyTmuxMarkerToken: "marker-token"
            )
        } else {
            nil
        }
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { _, _, _, _, _, _ in
                throw SSHError.shellRequestFailed
            },
            disconnect: {},
            closeShell: { _ in },
            execute: { _, _ in "" }
        )

        await SSHConnectionRunner.run(
            server: fixture.server,
            credentials: fixture.credentials,
            transport: transport,
            initialTerminalState: SSHConnectionInitialTerminalState(
                columns: 80,
                rows: 24,
                pixelSize: nil
            ),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true },
            onAttempt: { attempts.append($0) },
            startupPlan: {
                TerminalShellStartupPlan(
                    command: "notify-deployment",
                    remoteSessionLifecycle: lifecycle,
                    mayExecuteUserStartupAction: true
                )
            },
            setStartupActionReplayGuard: pendingStateRecorder.record,
            restoreMoshShell: { _, _ in nil },
            registerShell: { _, _ in true },
            onTitleChange: { _ in },
            writeOutput: { _ in true },
            shouldResetClient: { _ in false },
            onProcessExit: { _, _ in },
            onFailure: { error in reportedFailure = error as? SSHError }
        )

        #expect(attempts == [1])
        #expect(pendingStateRecorder.states == [true])
        guard case .startupCommandMayHaveRun = reportedFailure else {
            Issue.record("Expected the ambiguous startup-command failure")
            return
        }
    }

    @Test
    func unsupportedShellStartupActionPreservesTheActionableError() async {
        let fixture = makeFixture()
        var attempts: [Int] = []
        var reportedFailure: SSHError?
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { _, _, _, _, _, _ in
                throw SSHError.unsupportedRemoteShellForStartupCommand
            },
            disconnect: {},
            closeShell: { _ in },
            execute: { _, _ in "" }
        )

        await SSHConnectionRunner.run(
            server: fixture.server,
            credentials: fixture.credentials,
            transport: transport,
            initialTerminalState: SSHConnectionInitialTerminalState(
                columns: 80,
                rows: 24,
                pixelSize: nil
            ),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true },
            onAttempt: { attempts.append($0) },
            startupPlan: {
                TerminalShellStartupPlan(
                    command: "echo ready",
                    remoteSessionLifecycle: nil,
                    mayExecuteUserStartupAction: true
                )
            },
            restoreMoshShell: { _, _ in nil },
            registerShell: { _, _ in true },
            onTitleChange: { _ in },
            writeOutput: { _ in true },
            shouldResetClient: { _ in false },
            onProcessExit: { _, _ in },
            onFailure: { error in reportedFailure = error as? SSHError }
        )

        #expect(attempts == [1])
        guard case .unsupportedRemoteShellForStartupCommand = reportedFailure else {
            Issue.record("Expected the unsupported-shell startup error")
            return
        }
    }

    @Test(arguments: [false, true])
    func cancellationBeforeProcessRequestClearsReplayGuard(
        _ usesPersistentSession: Bool
    ) async throws {
        let fixture = makeFixture()
        let gate = SSHConnectionRunnerTestGate()
        let recorder = SSHConnectionRunnerTestRecorder()
        let pendingStateRecorder = SSHConnectionRunnerPendingStateRecorder()
        let startupCommand = "notify-deployment"
        let lifecycle: RemoteSessionLifecycleContext? = if usesPersistentSession {
            try RemoteSessionLifecycleContext(
                attachment: RemoteSessionAttachment(
                    identifier: RemoteSessionIdentifier(
                        backendIdentifier: .tmux,
                        validating: "vvterm-managed"
                    ),
                    ownership: .managed
                ),
                legacyTmuxMarkerToken: "marker-token"
            )
        } else {
            nil
        }
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { columns, rows, _, command, _, _ in
                #expect(command == startupCommand)
                await recorder.recordStart(columns: columns, rows: rows)
                await gate.suspend()
                try Task.checkCancellation()
                return fixture.shell
            },
            disconnect: {},
            closeShell: { _ in },
            execute: { _, _ in "" }
        )

        let task = Task {
            await run(
                fixture: fixture,
                transport: transport,
                startupPlan: {
                    TerminalShellStartupPlan(
                        command: startupCommand,
                        remoteSessionLifecycle: lifecycle,
                        mayExecuteUserStartupAction: true
                    )
                },
                setStartupActionReplayGuard: { isPending in
                    pendingStateRecorder.record(isPending)
                },
                registerShell: { _, _ in true }
            )
        }

        #expect(await gate.waitUntilSuspended())
        task.cancel()
        await gate.resume()
        await task.value

        #expect(await recorder.recordedStartSizes() == [[132, 43]])
        #expect(pendingStateRecorder.states == [true, false])
    }

    @Test(arguments: [false, true])
    func cancellationAfterProcessRequestStartsKeepsReplayGuard(
        _ usesPersistentSession: Bool
    ) async throws {
        let fixture = makeFixture()
        let gate = SSHConnectionRunnerTestGate()
        let pendingStateRecorder = SSHConnectionRunnerPendingStateRecorder()
        let lifecycle: RemoteSessionLifecycleContext? = if usesPersistentSession {
            try RemoteSessionLifecycleContext(
                attachment: RemoteSessionAttachment(
                    identifier: RemoteSessionIdentifier(
                        backendIdentifier: .tmux,
                        validating: "vvterm-managed"
                    ),
                    ownership: .managed
                ),
                legacyTmuxMarkerToken: "marker-token"
            )
        } else {
            nil
        }
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { _, _, _, _, _, _ in
                await gate.suspend()
                throw SSHError.processRequestOutcomeUnknown
            },
            disconnect: {},
            closeShell: { _ in },
            execute: { _, _ in "" }
        )

        let task = Task {
            await run(
                fixture: fixture,
                transport: transport,
                startupPlan: {
                    TerminalShellStartupPlan(
                        command: "notify-deployment",
                        remoteSessionLifecycle: lifecycle,
                        mayExecuteUserStartupAction: true
                    )
                },
                setStartupActionReplayGuard: pendingStateRecorder.record,
                registerShell: { _, _ in true }
            )
        }

        #expect(await gate.waitUntilSuspended())
        task.cancel()
        await gate.resume()
        await task.value

        #expect(pendingStateRecorder.states == [true])
    }

    @Test
    func managedActionReplayGuardClearsAfterAttachment() async throws {
        let fixture = makeFixture()
        let recorder = SSHConnectionRunnerTestRecorder()
        let pendingStateRecorder = SSHConnectionRunnerPendingStateRecorder()
        let envelope = RemoteSessionLifecycleEnvelope.make()
        let lifecycle = RemoteSessionLifecycleContext(
            attachment: RemoteSessionAttachment(
                identifier: try RemoteSessionIdentifier(
                    backendIdentifier: .tmux,
                    validating: "vvterm-managed"
                ),
                ownership: .managed
            ),
            envelope: envelope,
            presenceProbe: RemoteSessionPresenceProbe(
                command: "true",
                existsMarker: "exists",
                missingMarker: "missing"
            )
        )
        #expect(await fixture.channel.send(Data(
            RemoteSessionLifecycleMarker.sequence(envelope: envelope, event: .attached).utf8
        )))
        await fixture.channel.finish()

        await run(
            fixture: fixture,
            transport: makeTransport(
                shell: fixture.shell,
                recorder: recorder,
                startShell: { _, _ in }
            ),
            startupPlan: {
                TerminalShellStartupPlan(
                    command: "create-managed-session",
                    remoteSessionLifecycle: lifecycle,
                    mayExecuteUserStartupAction: true
                )
            },
            setStartupActionReplayGuard: pendingStateRecorder.record,
            onRemoteSessionAttached: {
                pendingStateRecorder.record(false)
            },
            registerShell: { _, _ in true }
        )

        #expect(pendingStateRecorder.states == [true, false])
    }

    @Test
    func completedStandaloneActionDoesNotRestoreDirectoryOrReconnect() async {
        let fixture = makeFixture()
        await fixture.channel.finish()
        var registeredPlan: TerminalShellStartupPlan?
        var endReason: TerminalShellEndReason?
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { _, _, _, _, _, _ in fixture.shell },
            disconnect: {},
            closeShell: { _ in },
            execute: { _, _ in "" }
        )

        await SSHConnectionRunner.run(
            server: fixture.server,
            credentials: fixture.credentials,
            transport: transport,
            initialTerminalState: SSHConnectionInitialTerminalState(
                columns: 80,
                rows: 24,
                pixelSize: nil
            ),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true },
            onAttempt: { _ in },
            startupPlan: {
                TerminalShellStartupPlan(
                    command: "exec vim",
                    remoteSessionLifecycle: nil,
                    mayExecuteUserStartupAction: true
                )
            },
            restoreMoshShell: { _, _ in nil },
            registerShell: { _, startupPlan in
                registeredPlan = startupPlan
                return true
            },
            onTitleChange: { _ in },
            writeOutput: { _ in true },
            shouldResetClient: { _ in false },
            onProcessExit: { _, reason in endReason = reason },
            onFailure: { error in
                Issue.record("Unexpected runner failure: \(error.localizedDescription)")
            }
        )

        #expect(registeredPlan?.mayExecuteStandaloneUserStartupAction == true)
        #expect(registeredPlan?.allowsPostLaunchWorkingDirectoryRestore == false)
        #expect(endReason == .standaloneStartupActionCompleted)
    }

    @Test
    func restoredMoshActionKeepsItsOneTimeCompletionState() async {
        let fixture = makeFixture()
        await fixture.channel.finish()
        var freshStartupRequested = false
        var registeredPlan: TerminalShellStartupPlan?
        var endReason: TerminalShellEndReason?
        let transport = SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { _, _, _, _, _, _ in
                Issue.record("A restored Mosh shell must not start a fresh shell")
                return fixture.shell
            },
            disconnect: {},
            closeShell: { _ in },
            execute: { _, _ in "" }
        )

        await SSHConnectionRunner.run(
            server: fixture.server,
            credentials: fixture.credentials,
            transport: transport,
            initialTerminalState: SSHConnectionInitialTerminalState(
                columns: 80,
                rows: 24,
                pixelSize: nil
            ),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true },
            onAttempt: { _ in },
            startupPlan: {
                freshStartupRequested = true
                return .plainShell
            },
            restoreMoshShell: { _, _ in
                SSHConnectionRestoredShell(
                    shell: fixture.shell,
                    remoteSessionLifecycle: nil,
                    startupActionReplayPending: true
                )
            },
            registerShell: { _, startupPlan in
                registeredPlan = startupPlan
                return true
            },
            onTitleChange: { _ in },
            writeOutput: { _ in true },
            shouldResetClient: { _ in false },
            onProcessExit: { _, reason in endReason = reason },
            onFailure: { error in
                Issue.record("Unexpected runner failure: \(error.localizedDescription)")
            }
        )

        #expect(!freshStartupRequested)
        #expect(registeredPlan?.mayExecuteStandaloneUserStartupAction == true)
        #expect(endReason == .standaloneStartupActionCompleted)
    }

    @Test
    func cancellationAfterShellOpenClosesUnregisteredShellExactlyOnce() async {
        let fixture = makeFixture()
        let gate = SSHConnectionRunnerTestGate()
        let recorder = SSHConnectionRunnerTestRecorder()
        let transport = makeTransport(
            shell: fixture.shell,
            recorder: recorder,
            startShell: { columns, rows in
                await recorder.recordStart(columns: columns, rows: rows)
                await gate.suspend()
            }
        )

        let task = Task {
            await run(
                fixture: fixture,
                transport: transport,
                registerShell: { _, _ in
                    await recorder.recordRegistration()
                    return true
                }
            )
        }

        #expect(await gate.waitUntilSuspended())
        task.cancel()
        await gate.resume()
        await task.value

        #expect(await recorder.recordedStartSizes() == [[132, 43]])
        #expect(await recorder.closeCount(for: fixture.shell.id) == 1)
        #expect(await recorder.registrations() == 0)
    }

    @Test
    func rejectedRegistrationLeavesShellCleanupToManagerOwner() async {
        let fixture = makeFixture()
        let recorder = SSHConnectionRunnerTestRecorder()
        let transport = makeTransport(
            shell: fixture.shell,
            recorder: recorder,
            startShell: { columns, rows in
                await recorder.recordStart(columns: columns, rows: rows)
            }
        )

        await run(
            fixture: fixture,
            transport: transport,
            registerShell: { _, _ in
                await recorder.recordRegistration()
                return false
            }
        )

        #expect(await recorder.recordedStartSizes() == [[132, 43]])
        #expect(await recorder.registrations() == 1)
        #expect(await recorder.closeCount(for: fixture.shell.id) == 0)
    }

    private struct Fixture {
        let server: Server
        let credentials: ServerCredentials
        let channel: TerminalOutputChannel
        let shell: ShellHandle
    }

    private func makeFixture() -> Fixture {
        let server = Server(
            workspaceId: UUID(),
            name: "Runner",
            host: "runner.example.invalid",
            username: "tester"
        )
        var credentials = ServerCredentials(serverId: server.id)
        credentials.credentialBinding = ServerCredentialBinding(server: server)
        let channel = TerminalOutputChannel()
        let shell = ShellHandle(
            id: UUID(),
            stream: TerminalOutputStream(channel: channel)
        )
        return Fixture(
            server: server,
            credentials: credentials,
            channel: channel,
            shell: shell
        )
    }

    private func makeTransport(
        shell: ShellHandle,
        recorder: SSHConnectionRunnerTestRecorder,
        startShell: @escaping @Sendable (_ columns: Int, _ rows: Int) async -> Void
    ) -> SSHConnectionRunnerTransport {
        SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { columns, rows, _, _, _, _ in
                await startShell(columns, rows)
                return shell
            },
            disconnect: {},
            closeShell: { shellId in
                await recorder.recordClose(shellId: shellId)
            },
            execute: { _, _ in "" }
        )
    }

    private func run(
        fixture: Fixture,
        transport: SSHConnectionRunnerTransport,
        startupPlan: @MainActor @escaping @Sendable () async throws
            -> TerminalShellStartupPlan = { .plainShell },
        setStartupActionReplayGuard: @MainActor @escaping @Sendable (
            Bool
        ) -> Void = { _ in },
        onRemoteSessionAttached: @MainActor @escaping @Sendable () -> Void = {},
        registerShell: @MainActor @escaping @Sendable (
            ShellHandle,
            TerminalShellStartupPlan
        ) async -> Bool
    ) async {
        await SSHConnectionRunner.run(
            server: fixture.server,
            credentials: fixture.credentials,
            transport: transport,
            initialTerminalState: SSHConnectionInitialTerminalState(
                columns: 132,
                rows: 43,
                pixelSize: nil
            ),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true },
            onAttempt: { _ in },
            startupPlan: startupPlan,
            setStartupActionReplayGuard: setStartupActionReplayGuard,
            onRemoteSessionAttached: onRemoteSessionAttached,
            restoreMoshShell: { _, _ in nil },
            registerShell: registerShell,
            onTitleChange: { _ in },
            writeOutput: { _ in true },
            shouldResetClient: { _ in false },
            onProcessExit: { _, _ in },
            onFailure: { error in
                Issue.record("Unexpected runner failure: \(error.localizedDescription)")
            }
        )
    }
}
