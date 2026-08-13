import Foundation

nonisolated enum SettingsGroup: String, CaseIterable, Hashable, Identifiable, Sendable {
    case account
    case app
    case terminal
    case dataAndSecurity
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account:
            String(localized: "Account")
        case .app:
            String(localized: "App")
        case .terminal:
            String(localized: "Terminal")
        case .dataAndSecurity:
            String(localized: "Data & Security")
        case .support:
            String(localized: "Support")
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
    case sessionsAndConnections
    case clipboardAndPaste
    case privacyAndAppLock
    case iCloudSync
    case sshKeys
    case trustedHosts
    case aboutAndSupport

    static let defaultRoute = SettingsRoute.appearanceAndLanguage

    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .pro:
            .account
        case .appearanceAndLanguage, .navigationAndStats:
            .app
        case .terminalAppearance, .keyboardAndInput, .transcription,
             .sessionsAndConnections, .clipboardAndPaste:
            .terminal
        case .privacyAndAppLock, .iCloudSync, .sshKeys, .trustedHosts:
            .dataAndSecurity
        case .aboutAndSupport:
            .support
        }
    }

    var title: String {
        switch self {
        case .pro:
            String(localized: "VVTerm Pro")
        case .appearanceAndLanguage:
            String(localized: "Appearance & Language")
        case .navigationAndStats:
            String(localized: "Navigation & Stats")
        case .privacyAndAppLock:
            String(localized: "Privacy & App Lock")
        case .terminalAppearance:
            String(localized: "Appearance")
        case .keyboardAndInput:
            String(localized: "Keyboard & Input")
        case .sessionsAndConnections:
            String(localized: "Sessions & Connections")
        case .clipboardAndPaste:
            String(localized: "Clipboard & Paste")
        case .sshKeys:
            String(localized: "SSH Keys")
        case .trustedHosts:
            String(localized: "Trusted Hosts")
        case .iCloudSync:
            String(localized: "iCloud Sync")
        case .transcription:
            String(localized: "Transcription")
        case .aboutAndSupport:
            String(localized: "About & Support")
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
            ["icloud", "sync", "cloudkit", "keychain", "resync"]
        case .transcription:
            ["voice", "speech", "transcription", "whisper", "parakeet", "model", "microphone"]
        case .aboutAndSupport:
            ["about", "support", "version", "help", "email", "discord", "website", "privacy policy", "terms"]
        }
    }
}

nonisolated enum SettingsRouteCatalog {
    static let groups = SettingsGroup.allCases

    static func routes(in group: SettingsGroup) -> [SettingsRoute] {
        SettingsRoute.allCases.filter { $0.group == group }
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
