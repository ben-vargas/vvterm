import Foundation

nonisolated enum SettingsGroup: String, CaseIterable, Hashable, Identifiable, Sendable {
    case general
    case terminal
    case connections
    case privacyAndData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            String(localized: "General")
        case .terminal:
            String(localized: "Terminal")
        case .connections:
            String(localized: "Connections")
        case .privacyAndData:
            String(localized: "Privacy & Data")
        }
    }
}

nonisolated enum SettingsRoute: String, CaseIterable, Hashable, Identifiable, Sendable {
    case pro
    case appearanceAndLanguage
    case navigationAndStats
    case terminalAppearance
    case keyboardAndInput
    case transcription
    case clipboardAndPaste
    case sessionsAndConnections
    case sshKeys
    case trustedHosts
    case privacyAndAppLock
    case iCloudSync
    case aboutAndSupport

    static let defaultRoute = SettingsRoute.appearanceAndLanguage

    var id: String { rawValue }

    var group: SettingsGroup? {
        switch self {
        case .pro:
            nil
        case .appearanceAndLanguage, .navigationAndStats:
            .general
        case .terminalAppearance, .keyboardAndInput, .transcription, .clipboardAndPaste:
            .terminal
        case .sessionsAndConnections, .sshKeys, .trustedHosts:
            .connections
        case .privacyAndAppLock, .iCloudSync:
            .privacyAndData
        case .aboutAndSupport:
            nil
        }
    }

    var title: String {
        switch self {
        case .pro:
            String(localized: "VVTerm Pro")
        case .appearanceAndLanguage:
            String(localized: "Appearance & Language")
        case .navigationAndStats:
            String(localized: "Server Views")
        case .privacyAndAppLock:
            String(localized: "Privacy & App Lock")
        case .terminalAppearance:
            String(localized: "Appearance")
        case .keyboardAndInput:
            String(localized: "Keyboard & Input")
        case .sessionsAndConnections:
            String(localized: "Sessions & SSH")
        case .clipboardAndPaste:
            String(localized: "Clipboard & Paste")
        case .sshKeys:
            String(localized: "SSH Keys")
        case .trustedHosts:
            String(localized: "Trusted Hosts")
        case .iCloudSync:
            String(localized: "iCloud Sync")
        case .transcription:
            String(localized: "Voice Input")
        case .aboutAndSupport:
            String(localized: "Help & About")
        }
    }

    var icon: String {
        switch self {
        case .pro:
            "sparkles"
        case .appearanceAndLanguage:
            "paintbrush"
        case .navigationAndStats:
            "sidebar.left"
        case .privacyAndAppLock:
            "lock.shield"
        case .terminalAppearance:
            "textformat"
        case .keyboardAndInput:
            "keyboard"
        case .sessionsAndConnections:
            "arrow.triangle.2.circlepath"
        case .clipboardAndPaste:
            "doc.on.clipboard"
        case .sshKeys:
            "key"
        case .trustedHosts:
            "checkmark.shield"
        case .iCloudSync:
            "icloud"
        case .transcription:
            "waveform"
        case .aboutAndSupport:
            "info.circle"
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .pro:
            ["subscription", "upgrade", "purchase", "billing", "restore", "plan"]
        case .appearanceAndLanguage:
            ["language", "system", "light", "dark", "theme", "color scheme"]
        case .navigationAndStats:
            ["server views", "view order", "default view", "reset views", "stats", "metrics", "dashboard"]
        case .privacyAndAppLock:
            ["privacy", "analytics", "biometric", "face id", "touch id", "lock", "background", "grace period"]
        case .terminalAppearance:
            ["font", "font size", "cursor", "blink", "light theme", "dark theme", "custom theme"]
        case .keyboardAndInput:
            ["keyboard", "input", "option", "alt", "terminal size", "dismiss", "screen awake", "accessory bar", "custom actions"]
        case .sessionsAndConnections:
            ["tmux", "session", "connect", "auto reconnect", "ssh", "keep alive", "keep-alive", "interval"]
        case .clipboardAndPaste:
            ["clipboard", "copy", "paste", "image", "whitespace", "ansi", "shell prompts", "remote clipboard"]
        case .sshKeys:
            ["ssh key", "private key", "public key", "passphrase", "generate", "import"]
        case .trustedHosts:
            ["trusted host", "fingerprint", "known hosts", "host key", "reset"]
        case .iCloudSync:
            [
                "icloud", "sync", "sync now", "cloudkit", "keychain", "credentials",
                "diagnostics", "network", "resync"
            ]
        case .transcription:
            ["voice", "speech", "transcription", "whisper", "parakeet", "model", "microphone"]
        case .aboutAndSupport:
            ["about", "support", "version", "help", "email", "discord", "website", "privacy policy", "terms"]
        }
    }
}

nonisolated enum SettingsRouteCatalog {
    static let leadingRoutes: [SettingsRoute] = [.pro]
    static let groups = SettingsGroup.allCases
    static let trailingRoutes: [SettingsRoute] = [.aboutAndSupport]

    static func routes(in group: SettingsGroup) -> [SettingsRoute] {
        SettingsRoute.allCases.filter { $0.group == group }
    }

    static func visibleRoutes(
        from routes: [SettingsRoute],
        matching query: String
    ) -> [SettingsRoute] {
        let matches = Set(Self.routes(matching: query))
        return routes.filter(matches.contains)
    }

    static func routes(matching query: String) -> [SettingsRoute] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return SettingsRoute.allCases }

        return SettingsRoute.allCases.filter { route in
            ([route.group.title, route.title] + route.searchKeywords)
                .contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }
}
