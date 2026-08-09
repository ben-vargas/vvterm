import Foundation

enum VVTermError: LocalizedError {
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

    var errorDescription: String? {
        switch self {
        case .proRequired(let message): return message
        case .serverLocked(let serverName):
            return String(format: String(localized: "Server '%@' is locked"), serverName)
        case .workspaceLocked(let workspaceName):
            return String(format: String(localized: "Workspace '%@' is locked"), workspaceName)
        case .moveNotAllowed(let message):
            return message
        case .connectionFailed(let message):
            return String(format: String(localized: "Connection failed: %@"), message)
        case .authenticationFailed:
            return String(localized: "Authentication failed")
        case .authorizationRequired:
            return String(localized: "Authorization is required")
        case .serverNotFound:
            return String(localized: "Server no longer exists.")
        case .workspaceNotFound:
            return String(localized: "Workspace no longer exists.")
        case .workspaceDeletionChanged:
            return String(localized: "The workspace changed while deletion was authorized. Review it and try again.")
        case .workspaceDeletionRecoveryPending:
            return String(localized: "The workspace was deleted, but cleanup is still pending and will retry.")
        case .timeout:
            return String(localized: "Connection timed out")
        }
    }

    var isLockedError: Bool {
        switch self {
        case .serverLocked, .workspaceLocked: return true
        default: return false
        }
    }
}
