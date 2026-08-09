nonisolated enum VVTermError: Error, Equatable, Sendable {
    case proRequired(String)
    case serverLocked(String)
    case workspaceLocked(String)
    case moveNotAllowed(String)
    case connectionFailed(String)
    case authenticationFailed
    case authorizationRequired
    case serverNotFound
    case workspaceNotFound
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
