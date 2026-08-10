import Foundation

@MainActor
private struct LiveServerStatsTarget: ServerStatsCollectionTarget {
    let server: Server

    var serverID: UUID { server.id }
}

@MainActor
private struct LiveServerStatsConnection: ServerStatsConnectionReference {
    let client: SSHClient

    var identity: ServerStatsConnectionIdentity {
        ServerStatsConnectionIdentity(client)
    }
}

@MainActor
final class LiveServerStatsApprovalReference: ServerStatsApprovalReference {
    let rawValue: ServerSecurityApprovalRequest
    let request: ServerStatsApprovalRequest

    init(_ rawValue: ServerSecurityApprovalRequest, serverID: UUID) {
        self.rawValue = rawValue
        switch rawValue {
        case .credentialEndpoint:
            request = ServerStatsApprovalRequest(
                id: rawValue.id,
                serverID: serverID,
                kind: .credentialEndpoint
            )
        case .hostKey:
            request = ServerStatsApprovalRequest(
                id: rawValue.id,
                serverID: serverID,
                kind: .hostKey
            )
        }
    }
}

@MainActor
extension ServerStatsCollectorDependencies {
    static func live(
        keychainManager: KeychainManager,
        connectionOperations: SSHConnectionOperationService
    ) -> Self {
        ServerStatsCollectorDependencies(
            makeOwnedConnection: {
                LiveServerStatsConnection(client: SSHClient())
            },
            makeSession: { target, connection, ownership in
                guard let target = target as? LiveServerStatsTarget,
                      let connection = connection as? LiveServerStatsConnection else {
                    throw LiveServerStatsAdapterError.incompatibleReference
                }

                let credentials: ServerCredentials
                do {
                    credentials = try keychainManager.getCredentials(for: target.server)
                } catch ServerCredentialAccessError.approvalRequired {
                    throw ServerStatsApprovalRequired(
                        reference: LiveServerStatsApprovalReference(
                            .credentialEndpoint(serverID: target.server.id),
                            serverID: target.server.id
                        )
                    )
                }

                return LiveServerStatsCollectionSession(
                    server: target.server,
                    credentials: credentials,
                    client: connection.client,
                    ownership: ownership,
                    connectionOperations: connectionOperations
                )
            },
            makeAttemptID: UUID.init
        )
    }
}

@MainActor
extension ServerStatsCollector {
    var securityApproval: ServerSecurityApprovalRequest? {
        (approvalReferenceForPresentation as? LiveServerStatsApprovalReference)?.rawValue
    }

    func startCollecting(
        for server: Server,
        using sharedClient: SSHClient? = nil,
        collectDocker: Bool = false
    ) async {
        await startCollecting(
            for: LiveServerStatsTarget(server: server),
            using: sharedClient.map(LiveServerStatsConnection.init(client:)),
            collectDocker: collectDocker
        )
    }

    func resolveSecurityApproval(
        _ request: ServerSecurityApprovalRequest,
        error: ServerSecurityApprovalError? = nil
    ) {
        guard let reference = approvalReferenceForPresentation as? LiveServerStatsApprovalReference,
              reference.rawValue == request else { return }
        resolveSecurityApproval(
            reference.request,
            errorMessage: error?.localizedDescription
        )
    }
}

// Existing state-focused callers stay concrete at the UI/test boundary. The
// Application state itself stores only the feature-owned approval DTO.
nonisolated extension ServerStatsCollectionState {
    var securityApproval: ServerSecurityApprovalRequest? {
        guard let request = approvalRequest else { return nil }
        switch request.kind {
        case .credentialEndpoint:
            return .credentialEndpoint(serverID: request.serverID)
        case .hostKey:
            return nil
        }
    }

    @discardableResult
    mutating func requireApproval(
        attemptID: UUID,
        request: ServerSecurityApprovalRequest
    ) -> Bool {
        guard case .credentialEndpoint(let serverID) = request else { return false }
        return requireApproval(
            attemptID: attemptID,
            request: ServerStatsApprovalRequest(
                id: request.id,
                serverID: serverID,
                kind: .credentialEndpoint
            )
        )
    }

    @discardableResult
    mutating func resolveApproval(
        _ request: ServerSecurityApprovalRequest,
        message: String? = nil
    ) -> Bool {
        guard approvalRequest?.id == request.id,
              let approvalRequest else { return false }
        return resolveApproval(approvalRequest, message: message)
    }
}

private enum LiveServerStatsAdapterError: LocalizedError {
    case incompatibleReference

    var errorDescription: String? {
        String(localized: "Stats received an incompatible connection reference.")
    }
}
