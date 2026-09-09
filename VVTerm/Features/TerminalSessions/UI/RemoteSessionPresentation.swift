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
        case .unsupportedVersion:
            return String(format: String(localized: "%@ unsupported"), backendName)
        case .unknown: return backendName
        }
    }

    var displayName: String {
        switch self {
        case .foreground: return "Foreground"
        case .background: return "Background"
        case .off: return "Off"
        case .missing: return "Unavailable"
        case .unsupportedVersion: return String(localized: "Unsupported version")
        case .unknown: return "Unknown"
        }
    }

    func setupPromptTitle(backendName: String) -> String? {
        switch self {
        case .missing:
            String(format: String(localized: "Install %@?"), backendName)
        case .unsupportedVersion:
            String(format: String(localized: "Unsupported %@ version"), backendName)
        case .foreground, .background, .off, .unknown:
            nil
        }
    }

    func setupPromptMessage(backendName: String) -> String? {
        switch self {
        case .missing:
            String(localized: "The selected option keeps the terminal alive across app restarts and disconnects.")
        case .unsupportedVersion(let version):
            String(
                format: String(localized: "VVTerm does not support %@. Update VVTerm or use a supported version of %@. You can continue without session persistence."),
                version,
                backendName
            )
        case .foreground, .background, .off, .unknown:
            nil
        }
    }
}
