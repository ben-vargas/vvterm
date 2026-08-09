import Foundation

enum SyncSettings {
    nonisolated static let enabledKey = CloudKitSyncConstants.syncEnabledKey

    nonisolated static var isEnabled: Bool {
        isEnabled(in: .standard)
    }

    nonisolated static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}
