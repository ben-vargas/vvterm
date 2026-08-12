nonisolated enum ServerProRequirement: Equatable, Sendable {
    case unlimitedServers
    case unlimitedWorkspaces
    case moveIntoLockedWorkspace
}

nonisolated enum ServerMoveFailureReason: Equatable, Sendable {
    case destinationUnavailable
    case unavailable
}

nonisolated enum VVTermError: Error, Equatable, Sendable {
    case proRequired(ServerProRequirement)
    case serverLocked(String)
    case workspaceLocked(String)
    case moveNotAllowed(ServerMoveFailureReason)
    case connectionFailed(String)
    case authenticationFailed
    case authorizationRequired
    case serverNotFound
    case serverMutationRecoveryPending
    case workspaceNotFound
    case environmentNotFound
    case environmentDeletionNotAllowed
    case environmentFallbackUnavailable
    case environmentDeletionRecoveryPending
    case workspaceDeletionChanged
    case workspaceDeletionRecoveryPending
    case timeout

    var isLockedError: Bool {
        switch self {
        case .serverLocked, .workspaceLocked: return true
        default: return false
        }
    }
}
