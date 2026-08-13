import SwiftUI

struct SyncSettingsStatusHero: View {
    let state: SyncSettingsUserState
    let lastSuccessfulSyncDate: Date?

    var body: some View {
        platformBody
    }
}

extension SyncSettingsUserState {
    var statusHeroSystemImage: String {
        switch self {
        case .upToDate:
            "icloud.fill"
        case .syncing:
            "icloud.and.arrow.up.fill"
        case .waitingForNetwork, .disabled:
            "icloud.slash.fill"
        case .signInToICloud:
            "person.crop.circle.badge.exclamationmark"
        case .needsAttention:
            "exclamationmark.icloud.fill"
        }
    }

    var statusHeroTint: Color {
        switch self {
        case .upToDate, .syncing:
            .blue
        case .waitingForNetwork, .signInToICloud:
            .orange
        case .needsAttention:
            .red
        case .disabled:
            .secondary
        }
    }
}

struct SyncSettingsStatusDetail: View {
    let state: SyncSettingsUserState
    let lastSuccessfulSyncDate: Date?

    var body: some View {
        Group {
            switch state {
            case .upToDate:
                if let lastSuccessfulSyncDate {
                    Text(
                        "Last synced \(lastSuccessfulSyncDate, format: .relative(presentation: .named))"
                    )
                } else {
                    Text("Ready to sync")
                }
            case .syncing:
                Text("Sync in progress")
            case .waitingForNetwork:
                Text("Changes will sync later.")
            case .signInToICloud:
                Text("Sign in to continue.")
            case .needsAttention:
                Text("Your data is safe.")
            case .disabled:
                Text("Data stays on this device.")
            }
        }
        .foregroundStyle(.secondary)
    }
}
