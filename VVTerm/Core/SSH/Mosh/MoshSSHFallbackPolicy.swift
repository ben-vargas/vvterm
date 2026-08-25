import Foundation

nonisolated enum MoshSSHFallbackDecision: Equatable, Sendable {
    case allow
    case rejectToPreventStartupCommandReplay
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
        guard let sshError = error as? SSHError else {
            return .rejectToPreventStartupCommandReplay
        }
        if sshError.provesStartupCommandWasNotDispatched {
            return .allow
        }

        switch sshError {
        case .moshServerMissing,
             .moshServerRuntimeBroken,
             .moshBootstrapFailedBeforeStartupCommand,
             .moshInvalidEndpoint:
            return .allow
        default:
            return .rejectToPreventStartupCommandReplay
        }
    }

    static func fallbackFailure(
        moshError: Error,
        fallbackError: Error
    ) -> SSHError {
        if let sshError = fallbackError as? SSHError {
            if sshError.provesStartupCommandWasNotDispatched {
                return sshError
            }
            if case .notConnected = sshError {
                return sshError
            }
        }
        return .moshSessionFailed(
            "Mosh startup failed (\(moshError.localizedDescription)); SSH fallback failed (\(fallbackError.localizedDescription))"
        )
    }
}
