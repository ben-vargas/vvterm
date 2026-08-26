import Foundation

extension RemoteSessionStartupBehavior {
    var displayName: String {
        switch self {
        case .createManaged:
            return String(localized: "Create VVTerm session")
        case .ask:
            return String(localized: "Ask every time")
        case .plainShell:
            return String(localized: "Use a normal shell")
        }
    }

    var descriptionText: String {
        switch self {
        case .createManaged:
            return String(localized: "Create or reconnect to a VVTerm-managed session.")
        case .ask:
            return String(localized: "Ask which session to use for each new tab or split.")
        case .plainShell:
            return String(localized: "Start a normal shell without remote session persistence.")
        }
    }
}

extension RemoteSessionStatus {
    func shortLabel(backendName: String) -> String {
        switch self {
        case .foreground: return backendName
        case .background: return backendName
        case .off: return "off"
        case .missing: return "\(backendName) missing"
        case .installing: return "\(backendName) install"
        case .unknown: return backendName
        }
    }

    var displayName: String {
        switch self {
        case .foreground: return "Foreground"
        case .background: return "Background"
        case .off: return "Off"
        case .missing: return "Unavailable"
        case .installing: return "Installing"
        case .unknown: return "Unknown"
        }
    }
}
