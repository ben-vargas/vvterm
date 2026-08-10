//
//  SyncSettingsView.swift
//  VVTerm
//

import SwiftUI

enum SyncSettingsAccountStatusText {
    static func text(for state: CloudKitAccountState) -> String {
        switch state {
        case .checking:
            String(localized: "Checking...")
        case .available:
            String(localized: "available")
        case .noAccount:
            String(localized: "noAccount - User not signed into iCloud")
        case .restricted:
            String(localized: "restricted - iCloud access restricted (parental controls, MDM, etc.)")
        case .couldNotDetermine:
            String(localized: "couldNotDetermine - Unable to determine iCloud status")
        case .temporarilyUnavailable:
            String(localized: "temporarilyUnavailable - iCloud temporarily unavailable")
        case .unknown(let rawValue):
            String(
                format: String(localized: "unknown status: %@"),
                String(rawValue)
            )
        case .failed(let detail):
            String(format: String(localized: "Error: %@"), detail)
        case .disabled:
            String(localized: "Disabled")
        }
    }
}

// MARK: - Sync Settings View

struct SyncSettingsView: View {
    @EnvironmentObject private var coordinator: SyncSettingsCoordinator
    @EnvironmentObject private var serverManager: ServerManager
    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager
    @EnvironmentObject private var terminalAccessory: TerminalAccessoryPreferencesManager
    @AppStorage(SyncSettings.enabledKey) private var syncEnabled = true
    @State private var confirmsCloudCredentialRemoval = false
    @State private var ignoresNextSyncToggleChange = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable iCloud Sync", isOn: $syncEnabled)

                HStack {
                    Label("iCloud Account", systemImage: "icloud")
                    Spacer()
                    statusBadge
                }

                if let credentialSyncError {
                    Text(credentialSyncError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Servers and selected credentials sync across your Apple devices. Credentials use iCloud Keychain.")
            }

            if syncEnabled {
                Section("Sync Status") {
                    HStack {
                        Text("Status")
                        Spacer()
                        syncStatusView
                    }

                    if let lastSync = coordinator.cloudState.lastSyncDate {
                        HStack {
                            Text("Last Synced")
                            Spacer()
                            Text(lastSync, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if case .error(let message) = coordinator.cloudState.status {
                        HStack {
                            Text("Error")
                            Spacer()
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Data") {
                    HStack {
                        Label("Workspaces", systemImage: "folder")
                        Spacer()
                        Text(serverManager.workspaces.count, format: .number)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Servers", systemImage: "server.rack")
                        Spacer()
                        Text(serverManager.servers.count, format: .number)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Custom Themes", systemImage: "paintpalette")
                        Spacer()
                        Text(customThemeCount, format: .number)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Accessory Items", systemImage: "keyboard")
                        Spacer()
                        Text(terminalAccessory.profile.layout.activeItems.count, format: .number)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Custom Actions", systemImage: "command.square")
                        Spacer()
                        Text(terminalAccessory.customActions.count, format: .number)
                            .foregroundStyle(.secondary)
                    }
                }

            } else {
                Section {
                    Button("Remove credentials from iCloud Keychain", role: .destructive) {
                        confirmsCloudCredentialRemoval = true
                    }
                } footer: {
                    Text("This removes VVTerm credentials from iCloud Keychain on all your Apple devices. Device-only credentials stay on this device.")
                }
            }

            // Debug section when CloudKit is unavailable
            if syncEnabled && !coordinator.cloudState.isAvailable {
                Section {
                    HStack {
                        Text("Account Status")
                        Spacer()
                        Text(SyncSettingsAccountStatusText.text(
                            for: coordinator.cloudState.accountState
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Container")
                        Spacer()
                        Text(String(localized: "iCloud.app.vivy.VivyTerm"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task {
                            await coordinator.refreshAccountStatus()
                        }
                    } label: {
                        Label("Re-check iCloud Status", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Make sure you are signed into iCloud in Settings and iCloud Drive is enabled. Check Console.app for 'CloudKit' logs for more details.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove credentials from iCloud Keychain",
            isPresented: $confirmsCloudCredentialRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove credentials from iCloud Keychain", role: .destructive) {
                coordinator.removeCloudCredentials()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes VVTerm credentials from iCloud Keychain on all your Apple devices. Device-only credentials stay on this device.")
        }
        .onChangeCompat(of: syncEnabled) { enabled in
            if ignoresNextSyncToggleChange {
                ignoresNextSyncToggleChange = false
                return
            }
            guard coordinator.setSyncEnabled(enabled) else {
                ignoresNextSyncToggleChange = true
                syncEnabled = !enabled
                return
            }
            if enabled {
                Task {
                    await coordinator.refreshAfterSyncEnabled()
                }
            }
        }
    }

    private var customThemeCount: Int {
        terminalThemeManager.customThemes.filter { !$0.isDeleted }.count
    }

    private var credentialSyncError: String? {
        switch coordinator.credentialFailure {
        case .toggle:
            return String(localized: "Credentials could not be copied. Existing credentials were kept.")
        case .removal:
            return String(
                localized: "Some iCloud Keychain credentials could not be removed. Device-only credentials were kept."
            )
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !syncEnabled {
            Label("Disabled", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if coordinator.cloudState.isAvailable {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Not Available", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch coordinator.cloudState.status {
        case .idle:
            Label("Synced", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing...")
            }
            .foregroundStyle(.orange)
        case .error:
            Label("Error", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .offline:
            Label("Offline", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        case .disabled:
            Label("Disabled", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        }
    }

}
