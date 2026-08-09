import Foundation

nonisolated enum ServerSecurityApprovalRequest: Identifiable, Equatable, Sendable {
    case credentialEndpoint(serverID: UUID)
    case hostKey(KnownHostsManager.Challenge)

    var id: String {
        switch self {
        case .credentialEndpoint(let serverID):
            "credential:\(serverID.uuidString)"
        case .hostKey(let challenge):
            "host-key:\(challenge.id.uuidString)"
        }
    }

    static func detect(
        _ error: Error,
        server: Server,
        knownHosts: KnownHostsManager = .shared
    ) -> Self? {
        if error as? ServerCredentialAccessError == .approvalRequired {
            return .credentialEndpoint(serverID: server.id)
        }
        if let sshError = error as? SSHError,
           case .hostKeyApprovalRequired = sshError,
           let challenge = knownHosts.pendingChallenge(
               for: server.host,
               port: server.port
           ) {
            return .hostKey(challenge)
        }
        return nil
    }
}

nonisolated enum ServerSecurityApprovalError: LocalizedError, Equatable, Sendable {
    case cancelled
    case expired
    case unavailable

    var errorDescription: String? {
        switch self {
        case .cancelled:
            String(localized: "Security approval was cancelled.")
        case .expired:
            String(localized: "Security approval expired. Try again.")
        case .unavailable:
            String(localized: "Security approval is no longer available. Try again.")
        }
    }
}

nonisolated struct ServerCredentialApprovalPresentation {
    let title = String(localized: "Approve Credential Endpoint?")
    let approvalButtonTitle = String(localized: "Approve and Retry")
    let message: String

    init(server: Server) {
        message = String(
            format: String(localized: "Stored credentials were saved for another endpoint. Use them with %@:%lld only if you trust this change."),
            server.host,
            Int64(server.port)
        )
    }
}
