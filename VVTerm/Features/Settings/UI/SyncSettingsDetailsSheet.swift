import SwiftUI

struct SyncSettingsDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingCredentialRemoval = false

    let summary: SyncSettingsContentSummary
    let syncEnabled: Bool
    let lastSuccessfulSyncDate: Date?
    let pendingChangeCount: Int
    let lastError: SyncSettingsErrorRecord?
    let diagnostics: String
    let removeCredentialsFromICloud: () -> Void

    var body: some View {
        NavigationStack {
            SyncSettingsDetailsContent(
                summary: summary,
                syncEnabled: syncEnabled,
                lastSuccessfulSyncDate: lastSuccessfulSyncDate,
                pendingChangeCount: pendingChangeCount,
                lastError: lastError,
                diagnostics: diagnostics,
                requestCredentialRemoval: {
                    isConfirmingCredentialRemoval = true
                }
            )
            .navigationTitle("iCloud Sync Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .syncSettingsDetailsPresentation()
        .confirmationDialog(
            "Remove Credentials from iCloud Keychain?",
            isPresented: $isConfirmingCredentialRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from iCloud Keychain", role: .destructive) {
                removeCredentialsFromICloud()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Credentials remain on this device. If you enable sync again, VVTerm will store them in iCloud Keychain again.")
        }
    }
}

private struct SyncSettingsDetailsContent: View {
    let summary: SyncSettingsContentSummary
    let syncEnabled: Bool
    let lastSuccessfulSyncDate: Date?
    let pendingChangeCount: Int
    let lastError: SyncSettingsErrorRecord?
    let diagnostics: String
    let requestCredentialRemoval: () -> Void

    var body: some View {
        Form {
            appDataSection
            settingsSection
            credentialsSection
            deviceOnlySection
            syncDetailsSection
            if !syncEnabled {
                credentialRemovalSection
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.sync.details")
    }

    private var appDataSection: some View {
        Section("App Data") {
            SyncSettingsDetailsCountRow(
                title: "Workspaces",
                systemImage: "folder",
                count: summary.workspaceCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.workspaces"
            )
            SyncSettingsDetailsCountRow(
                title: "Servers",
                systemImage: "server.rack",
                count: summary.serverCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.servers"
            )
            SyncSettingsDetailsCountRow(
                title: "Custom Themes",
                systemImage: "paintpalette",
                count: summary.customThemeCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.customThemes"
            )
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            SyncSettingsDetailsStatusRow(
                title: "Terminal Appearance",
                systemImage: "circle.lefthalf.filled",
                status: storageStatus
            )
            SyncSettingsDetailsStatusRow(
                title: "Keyboard Toolbar",
                systemImage: "keyboard",
                status: storageStatus
            )
            SyncSettingsDetailsStatusRow(
                title: "Stats Layout",
                systemImage: "chart.xyaxis.line",
                status: storageStatus
            )
        }
    }

    private var credentialsSection: some View {
        Section {
            SyncSettingsDetailsCountRow(
                title: "Server Credentials",
                systemImage: "key.fill",
                count: summary.serverCredentialCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.serverCredentials"
            )
            SyncSettingsDetailsCountRow(
                title: "Reusable SSH Keys",
                systemImage: "key.horizontal.fill",
                count: summary.reusableSSHKeyCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.reusableSSHKeys"
            )
            SyncSettingsDetailsStatusRow(
                title: "Cloudflare Tokens",
                systemImage: "lock.shield",
                status: storageStatus
            )
        } header: {
            Text("Credentials")
        } footer: {
            Text("Passwords, private keys, passphrases, and Cloudflare tokens use iCloud Keychain.")
        }
    }

    private var deviceOnlySection: some View {
        Section("Stays on This Device") {
            SyncSettingsDetailsCountRow(
                title: "Open Terminals",
                systemImage: "terminal",
                count: summary.openTerminalCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.openTerminals"
            )
            SyncSettingsDetailsStatusRow(
                title: "Session Resume Data",
                systemImage: "arrow.clockwise.circle",
                status: "Device Only"
            )
            SyncSettingsDetailsStatusRow(
                title: "Device Identity",
                systemImage: "iphone",
                status: "Device Only"
            )
            SyncSettingsDetailsStatusRow(
                title: "Cache and Logs",
                systemImage: "doc.text",
                status: "Device Only"
            )
        }
    }

    private var syncDetailsSection: some View {
        Section("Sync Details") {
            if let lastSuccessfulSyncDate {
                LabeledContent("Last Successful Sync") {
                    Text(
                        lastSuccessfulSyncDate,
                        format: .dateTime.year().month().day().hour().minute()
                    )
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("vvterm.settings.sync.details.lastSuccessful")
            }

            if pendingChangeCount > 0 {
                LabeledContent("Pending Changes") {
                    Text(pendingChangeCount, format: .number)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("vvterm.settings.sync.details.pendingChanges")
            }

            if let lastError {
                LabeledContent("Last Sync Error") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(lastError.category.title)
                        Text(
                            lastError.date,
                            format: .dateTime.year().month().day().hour().minute()
                        )
                        .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("vvterm.settings.sync.details.lastError")
            }

            Button {
                Clipboard.copy(diagnostics)
            } label: {
                Label("Copy Sync Diagnostics", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("vvterm.settings.sync.copyDiagnostics")
        }
    }

    private var credentialRemovalSection: some View {
        Section {
            Button(role: .destructive, action: requestCredentialRemoval) {
                Label("Remove Credentials from iCloud Keychain", systemImage: "key.slash")
            }
            .accessibilityIdentifier("vvterm.settings.sync.removeCredentials")
        } footer: {
            Text("Credentials remain on this device. Existing app data in iCloud is not deleted.")
        }
    }

    private var storageStatus: LocalizedStringResource {
        syncEnabled ? "Synced" : "On This Device"
    }
}

private struct SyncSettingsDetailsCountRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let count: Int
    let accessibilityIdentifier: String

    var body: some View {
        LabeledContent {
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct SyncSettingsDetailsStatusRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let status: LocalizedStringResource

    var body: some View {
        LabeledContent {
            Text(status)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
