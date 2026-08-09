import Foundation

extension BiometryKind {
    var displayName: String {
        switch self {
        case .none:
            return String(localized: "Biometric Authentication")
        case .touchID:
            return String(localized: "Touch ID")
        case .faceID:
            return String(localized: "Face ID")
        }
    }
}
