import Foundation

nonisolated enum MoshSSHFallbackDecision: Equatable, Sendable {
    case allow
    case rejectToPreventStartupCommandReplay
}

nonisolated enum MoshSSHFallbackPolicy {
    static func decision(
        after reason: MoshFallbackReason,
        startupCommand: String?
    ) -> MoshSSHFallbackDecision {
        let command = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { return .allow }

        switch reason {
        case .serverMissing,
             .serverRuntimeBroken,
             .unsupportedRemoteCapabilities,
             .invalidEndpoint:
            return .allow
        case .bootstrapFailed,
             .sessionFailed,
             .udpTimeout,
             .clientSessionFailed:
            return .rejectToPreventStartupCommandReplay
        }
    }
}
