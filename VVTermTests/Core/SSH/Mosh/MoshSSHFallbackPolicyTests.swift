import Testing
@testable import VVTerm

struct MoshSSHFallbackPolicyTests {
    @Test
    func successfulBootstrapThenUDPFailureDoesNotReplayStartupCommand() {
        var executionCount = 1

        if MoshSSHFallbackPolicy.decision(
            after: .udpTimeout,
            startupCommand: "deploy --start"
        ) == .allow {
            executionCount += 1
        }

        #expect(executionCount == 1)
    }

    @Test(arguments: [
        MoshFallbackReason.bootstrapFailed,
        .sessionFailed,
        .udpTimeout,
        .clientSessionFailed
    ])
    func commandBlocksFallbackWhenRemoteExecutionIsPossible(_ reason: MoshFallbackReason) {
        #expect(MoshSSHFallbackPolicy.decision(
            after: reason,
            startupCommand: "notify-send started"
        ) == .rejectToPreventStartupCommandReplay)
    }

    @Test(arguments: [
        MoshFallbackReason.serverMissing,
        .serverRuntimeBroken,
        .unsupportedRemoteCapabilities,
        .invalidEndpoint
    ])
    func commandAllowsFallbackBeforeRemoteExecution(_ reason: MoshFallbackReason) {
        #expect(MoshSSHFallbackPolicy.decision(
            after: reason,
            startupCommand: "echo once"
        ) == .allow)
    }

    @Test
    func normalShellCanFallbackForEveryFailureReason() {
        for reason in MoshFallbackReason.allCases {
            #expect(MoshSSHFallbackPolicy.decision(
                after: reason,
                startupCommand: "  "
            ) == .allow)
        }
    }
}
