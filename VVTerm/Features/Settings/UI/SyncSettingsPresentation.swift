import Foundation

enum SyncSettingsPrimaryAction: Equatable {
    case syncNow
    case tryAgain
    case checkAgain
    case syncing

    var title: LocalizedStringResource {
        switch self {
        case .syncNow: "Sync Now"
        case .tryAgain: "Try Again"
        case .checkAgain: "Check Again"
        case .syncing: "Syncing"
        }
    }

    var systemImage: String {
        switch self {
        case .syncNow, .tryAgain, .syncing:
            "arrow.triangle.2.circlepath"
        case .checkAgain:
            "arrow.clockwise"
        }
    }

    var isRunning: Bool {
        self == .syncing
    }
}

extension SyncSettingsContentSummary {
    var appDataSummaryText: String {
        [
            localizedWorkspaceCount,
            localizedServerCount,
            localizedCustomThemeCount,
        ]
        .joined(separator: " · ")
    }

    var credentialSummaryText: String {
        [
            localizedServerCredentialCount,
            localizedReusableSSHKeyCount,
        ]
        .joined(separator: " · ")
    }

    private var localizedWorkspaceCount: String {
        localizedCount(
            workspaceCount,
            singular: "%lld workspace",
            plural: "%lld workspaces"
        )
    }

    private var localizedServerCount: String {
        localizedCount(
            serverCount,
            singular: "%lld server",
            plural: "%lld servers"
        )
    }

    private var localizedCustomThemeCount: String {
        localizedCount(
            customThemeCount,
            singular: "%lld custom theme",
            plural: "%lld custom themes"
        )
    }

    private var localizedServerCredentialCount: String {
        localizedCount(
            serverCredentialCount,
            singular: "%lld server credential",
            plural: "%lld server credentials"
        )
    }

    private var localizedReusableSSHKeyCount: String {
        localizedCount(
            reusableSSHKeyCount,
            singular: "%lld SSH key",
            plural: "%lld SSH keys"
        )
    }

    private func localizedCount(
        _ count: Int,
        singular: String.LocalizationValue,
        plural: String.LocalizationValue
    ) -> String {
        let format = count == 1
            ? String(localized: singular)
            : String(localized: plural)
        return String(format: format, Int64(count))
    }
}

extension SyncSettingsUserState {
    var title: String {
        switch self {
        case .upToDate: String(localized: "Up to Date")
        case .syncing: String(localized: "Syncing")
        case .waitingForNetwork: String(localized: "Waiting for Network")
        case .signInToICloud: String(localized: "Sign In to iCloud")
        case .needsAttention: String(localized: "Sync Needs Attention")
        case .disabled: String(localized: "Sync is Off")
        }
    }

    var appDataStatusTitle: LocalizedStringResource {
        switch self {
        case .upToDate: "Up to Date"
        case .syncing: "Syncing"
        case .waitingForNetwork: "Waiting for Network"
        case .signInToICloud: "Sign In to iCloud"
        case .needsAttention: "Needs Attention"
        case .disabled: "On This Device"
        }
    }

    var recoveryGuidance: String? {
        switch self {
        case .waitingForNetwork:
            String(localized: "Check your network connection.")
        case .signInToICloud:
            String(localized: "Sign in to iCloud and turn on iCloud Drive.")
        case .needsAttention:
            String(localized: "Try syncing again. Your changes are safe.")
        case .upToDate, .syncing, .disabled:
            nil
        }
    }
}

extension SyncSettingsCredentialState {
    var statusTitle: LocalizedStringResource {
        switch self {
        case .storedInICloudKeychain: "iCloud Keychain"
        case .storedOnThisDevice: "On This Device"
        case .needsAttention: "Needs Attention"
        }
    }
}

extension SyncSettingsErrorCategory {
    var title: LocalizedStringResource {
        switch self {
        case .account: "Account"
        case .cloudData: "App Data"
        case .credentials: "Credentials"
        case .network: "Network"
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
