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
            .moshClientSessionFailed("client failure")
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
            .moshBootstrapFailedBeforeStartupCommand("rejected")
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
}
