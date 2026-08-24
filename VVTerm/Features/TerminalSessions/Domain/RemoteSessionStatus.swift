import Foundation

nonisolated enum RemoteSessionStatus: String, Codable, Hashable, Sendable {
    case foreground
    case background
    case off
    case missing
    case installing
    case unknown

    var indicatesPersistentSession: Bool {
        switch self {
        case .foreground, .background, .unknown:
            true
        case .off, .missing, .installing:
            false
        }
    }
}
