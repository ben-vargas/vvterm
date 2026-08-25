import Testing
@testable import VVTerm

struct MoshSSHFallbackPolicyTests {
    @Test
    func successfulBootstrapThenUDPFailureDoesNotReplayStartupCommand() {
        var executionCount = 1

        if MoshSSHFallbackPolicy.decision(
            after: SSHError.moshUDPTimeout,
            startupCommand: "deploy --start",
            mayExecuteUserStartupAction: true
        ) == .allow {
            executionCount += 1
        }

        #expect(executionCount == 1)
    }

    @Test
    func commandBlocksFallbackWhenRemoteExecutionIsPossible() {
        let errors: [SSHError] = [
            .moshBootstrapFailed("ambiguous bootstrap failure"),
            .moshSessionFailed("session failure"),
            .moshUDPTimeout,
            .moshClientSessionFailed("client failure"),
            .notConnected
        ]

        for error in errors {
            #expect(MoshSSHFallbackPolicy.decision(
                after: error,
                startupCommand: "notify-send started",
                mayExecuteUserStartupAction: true
            ) == .rejectToPreventStartupCommandReplay)
        }
    }

    @Test
    func preExecutionBootstrapFailureFallsBackAndRunsCommandOnce() {
        var executionCount = 0

        #expect(MoshSSHFallbackPolicy.decision(
            after: SSHError.moshBootstrapFailedBeforeStartupCommand(
                "mosh-server rejected startup"
            ),
            startupCommand: "notify-send started",
            mayExecuteUserStartupAction: true
        ) == .allow)
        executionCount += 1

        #expect(executionCount == 1)
    }

    @Test
    func commandAllowsFallbackBeforeRemoteExecution() {
        let errors: [SSHError] = [
            .moshServerMissing,
            .moshServerRuntimeBroken,
            .moshInvalidEndpoint,
            .moshBootstrapFailedBeforeStartupCommand("rejected"),
            .channelOpenFailed
        ]

        for error in errors {
            #expect(MoshSSHFallbackPolicy.decision(
                after: error,
                startupCommand: "echo once",
                mayExecuteUserStartupAction: true
            ) == .allow)
        }
    }

    @Test
    func managedSessionLauncherWithoutUserActionCanFallbackAfterBootstrap() {
        #expect(MoshSSHFallbackPolicy.decision(
            after: SSHError.moshUDPTimeout,
            startupCommand: "tmux new-session -A -s vvterm-workstation",
            mayExecuteUserStartupAction: false
        ) == .allow)
    }

    @Test
    func normalShellCanFallbackForEveryFailureReason() {
        let errors: [SSHError] = [
            .moshServerMissing,
            .moshServerRuntimeBroken,
            .moshBootstrapFailed("failed"),
            .moshBootstrapFailedBeforeStartupCommand("rejected"),
            .moshSessionFailed("failed"),
            .moshInvalidEndpoint,
            .moshUDPTimeout,
            .moshClientSessionFailed("failed")
        ]

        for error in errors {
            #expect(MoshSSHFallbackPolicy.decision(
                after: error,
                startupCommand: "  ",
                mayExecuteUserStartupAction: false
            ) == .allow)
        }
    }

    @Test
    func fallbackPreservesFailuresBeforeStartupCommandDispatch() {
        let moshError = SSHError.moshServerMissing
        let channel = MoshSSHFallbackPolicy.fallbackFailure(
            moshError: moshError,
            fallbackError: SSHError.channelOpenFailed
        )
        let disconnected = MoshSSHFallbackPolicy.fallbackFailure(
            moshError: moshError,
            fallbackError: SSHError.disconnectedBeforeShellRequest
        )
        let shellRequest = MoshSSHFallbackPolicy.fallbackFailure(
            moshError: moshError,
            fallbackError: SSHError.shellRequestFailed
        )

        guard case .channelOpenFailed = channel else {
            Issue.record("Expected the channel-open error")
            return
        }
        guard case .disconnectedBeforeShellRequest = disconnected else {
            Issue.record("Expected the pre-request disconnect")
            return
        }
        guard case .shellRequestFailed = shellRequest else {
            Issue.record("Expected the shell-request error")
            return
        }
    }
}
