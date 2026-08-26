import Testing
@testable import VVTerm

struct MoshSSHFallbackPolicyTests {
    @Test
    func successfulBootstrapThenUDPFailureDoesNotReplayStartupCommand() {
        var executionCount = 1

        if MoshSSHFallbackPolicy.decision(
            after: failure(stage: .udpClientStartingOrStarted),
            startupCommand: "deploy --start",
            mayExecuteUserStartupAction: true
        ) == .allow {
            executionCount += 1
        }

        #expect(executionCount == 1)
    }

    @Test
    func commandBlocksFallbackWhenRemoteExecutionIsPossible() {
        let errors: [MoshStartupFailure] = [
            failure(stage: .udpClientStartingOrStarted, underlying: .moshUDPTimeout),
            failure(stage: .udpClientStartingOrStarted, underlying: .moshClientSessionFailed("failed")),
            failure(stage: .udpClientStartingOrStarted, underlying: .notConnected)
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
            after: failure(
                stage: .beforeUDPClient,
                underlying: .moshBootstrapFailed("mosh-server rejected startup")
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
            .moshBootstrapFailed("invalid connect output"),
            .timeout
        ]

        for error in errors {
            #expect(MoshSSHFallbackPolicy.decision(
                after: failure(stage: .beforeUDPClient, underlying: error),
                startupCommand: "echo once",
                mayExecuteUserStartupAction: true
            ) == .allow)
        }
    }

    @Test
    func managedSessionLauncherWithoutUserActionCanFallbackAfterBootstrap() {
        #expect(MoshSSHFallbackPolicy.decision(
            after: failure(stage: .udpClientStartingOrStarted),
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
            fallbackError: SSHError.processRequestDenied
        )

        guard case .channelOpenFailed = channel else {
            Issue.record("Expected the channel-open error")
            return
        }
        guard case .disconnectedBeforeShellRequest = disconnected else {
            Issue.record("Expected the pre-request disconnect")
            return
        }
        guard case .processRequestDenied = shellRequest else {
            Issue.record("Expected the process-request denial")
            return
        }
    }

    @Test
    func fallbackPreservesUnknownProcessRequestOutcome() {
        let result = MoshSSHFallbackPolicy.fallbackFailure(
            moshError: failure(stage: .beforeUDPClient),
            fallbackError: SSHError.processRequestOutcomeUnknown
        )

        guard case .processRequestOutcomeUnknown = result else {
            Issue.record("Expected the ambiguous process-request error")
            return
        }
    }

    private func failure(
        stage: MoshStartupDispatchStage,
        underlying: SSHError = .moshUDPTimeout
    ) -> MoshStartupFailure {
        MoshStartupFailure(stage: stage, underlying: underlying)
    }
}
