import Foundation

enum SyncSettings {
    static let enabledKey = CloudKitSyncConstants.syncEnabledKey

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}
