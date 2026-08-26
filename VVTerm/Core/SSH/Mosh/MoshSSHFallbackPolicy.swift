import Foundation

nonisolated enum MoshSSHFallbackDecision: Equatable, Sendable {
    case allow
    case rejectToPreventStartupCommandReplay
}

nonisolated enum MoshStartupDispatchStage: Equatable, Sendable {
    case beforeUDPClient
    case udpClientStartingOrStarted
}

nonisolated struct MoshStartupFailure: LocalizedError, Sendable {
    let stage: MoshStartupDispatchStage
    let underlying: SSHError

    var errorDescription: String? {
        underlying.errorDescription
    }
}

nonisolated enum MoshSSHFallbackPolicy {
    static func decision(
        after error: Error,
        startupCommand: String?,
        mayExecuteUserStartupAction: Bool
    ) -> MoshSSHFallbackDecision {
        let command = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { return .allow }
        guard mayExecuteUserStartupAction else { return .allow }
        guard let failure = error as? MoshStartupFailure else {
            return .rejectToPreventStartupCommandReplay
        }
        return failure.stage == .beforeUDPClient
            ? .allow
            : .rejectToPreventStartupCommandReplay
    }

    static func fallbackFailure(
        moshError _: Error,
        fallbackError: Error
    ) -> SSHError {
        if let sshError = fallbackError as? SSHError {
            return sshError
        }
        return .moshSessionFailed(
            "Mosh and SSH startup both failed"
        )
    }
}
