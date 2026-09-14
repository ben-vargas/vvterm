import Foundation

/// The app preference is separate from permission granted in system settings.
nonisolated enum TerminalNotificationPreferences {
    static let enabledKey = "terminal.notificationsEnabled"
    static let defaultEnabled = true

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}
