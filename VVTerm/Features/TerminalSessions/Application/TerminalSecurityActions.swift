import Foundation

nonisolated enum TerminalSecurityApprovalRequest: Identifiable, Equatable, Sendable {
    case hostKey(KnownHostsManager.Challenge)

    var id: String {
        switch self {
        case .hostKey(let challenge):
            "host-key:\(challenge.id.uuidString)"
        }
    }
}

nonisolated enum TerminalSecurityApprovalFailure: Equatable, Sendable {
    case expired
}

nonisolated enum TerminalSecurityApprovalOutcome: Equatable, Sendable {
    case approved
    case failed(TerminalSecurityApprovalFailure)
}

/// App-owned security effects used by terminal session presentation.
@MainActor
struct TerminalSecurityActions {
    typealias LoadCredentials = @MainActor @Sendable (Server) throws -> ServerCredentials
    typealias PendingHostKeyApproval = @MainActor @Sendable (
        _ server: Server
    ) -> TerminalSecurityApprovalRequest?
    typealias Approve = @MainActor @Sendable (
        _ request: TerminalSecurityApprovalRequest,
        _ server: Server
    ) -> TerminalSecurityApprovalOutcome
    typealias Reject = @MainActor @Sendable (
        _ request: TerminalSecurityApprovalRequest
    ) -> Void

    let loadCredentials: LoadCredentials
    let pendingHostKeyApproval: PendingHostKeyApproval
    let approve: Approve
    let reject: Reject
}
