import Foundation

extension SyncSettingsUserState {
    var title: String {
        switch self {
        case .upToDate: String(localized: "Up to Date")
        case .syncing: String(localized: "Syncing")
        case .waitingForNetwork: String(localized: "Waiting for Network")
        case .signInToICloud: String(localized: "Sign In to iCloud")
        case .needsAttention: String(localized: "Sync Needs Attention")
        case .disabled: String(localized: "Sync Disabled")
        }
    }

    var appDataServiceTitle: String {
        switch self {
        case .upToDate: String(localized: "Up to Date")
        case .syncing: String(localized: "Syncing")
        case .waitingForNetwork: String(localized: "Changes will sync later")
        case .signInToICloud: String(localized: "Sign in required")
        case .needsAttention: String(localized: "Needs attention")
        case .disabled: String(localized: "Stored on this device")
        }
    }

    var recoveryGuidance: String {
        switch self {
        case .waitingForNetwork:
            String(localized: "Check your network connection. Pending changes remain on this device and will sync later.")
        case .signInToICloud:
            String(localized: "Sign in to iCloud and enable iCloud Drive in System Settings, then check again.")
        case .needsAttention:
            String(localized: "Check iCloud status and try Sync Now again. Your pending changes remain on this device.")
        case .disabled:
            String(localized: "Enable iCloud Sync to sync data between your Apple devices.")
        case .upToDate, .syncing:
            String(localized: "Use Check iCloud Status to verify account access, or Sync Now to start a complete sync.")
        }
    }

    var needsTroubleshooting: Bool {
        switch self {
        case .waitingForNetwork, .signInToICloud, .needsAttention:
            true
        case .upToDate, .syncing, .disabled:
            false
        }
    }
}

extension SyncSettingsCredentialState {
    var title: String {
        switch self {
        case .storedInICloudKeychain:
            String(localized: "Stored in iCloud Keychain")
        case .storedOnThisDevice:
            String(localized: "Stored on this device")
        case .needsAttention:
            String(localized: "Needs attention")
        }
    }
}

extension SyncSettingsManualSyncState {
    var announcement: String? {
        switch self {
        case .success:
            String(localized: "iCloud Sync completed.")
        case .waitingForNetwork:
            String(localized: "iCloud Sync is waiting for the network.")
        case .accountActionRequired:
            String(localized: "Sign in to iCloud to sync.")
        case .failure:
            String(localized: "iCloud Sync needs attention.")
        case .idle, .running:
            nil
        }
    }
}
