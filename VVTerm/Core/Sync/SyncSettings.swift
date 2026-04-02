import Foundation

enum SyncSettings {
    nonisolated static let enabledKey = CloudKitSyncConstants.syncEnabledKey

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}
