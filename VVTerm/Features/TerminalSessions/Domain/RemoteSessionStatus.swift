import Foundation

nonisolated enum RemoteSessionStatus: Hashable, Sendable {
    case foreground
    case background
    case off
    case missing
    case unsupportedVersion(String)
    case unknown

    var indicatesPersistentSession: Bool {
        switch self {
        case .foreground, .background, .unknown:
            true
        case .off, .missing, .unsupportedVersion:
            false
        }
    }
}
