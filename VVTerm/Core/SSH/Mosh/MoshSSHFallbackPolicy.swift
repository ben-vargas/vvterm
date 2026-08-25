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

        switch sshError {
        case .channelOpenFailed,
             .disconnectedBeforeShellRequest,
             .moshServerMissing,
             .moshServerRuntimeBroken,
             .moshBootstrapFailedBeforeStartupCommand,
             .moshInvalidEndpoint:
            return .allow
        default:
            return .rejectToPreventStartupCommandReplay
        }
    }
}
