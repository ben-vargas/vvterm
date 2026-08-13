import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject private var coordinator: SyncSettingsCoordinator
    @State private var syncEnabled = SyncSettings.isEnabled
    @State private var ignoresNextSyncToggleChange = false
    @State private var isConfirmingCredentialRemoval = false

    var body: some View {
        Form {
            syncSection
            dataSection
            if let attentionMessage {
                troubleshootingSection(message: attentionMessage)
            }
            advancedSection
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.iCloudSync")
        .onAppear {
            coordinator.refreshSnapshots()
        }
        .onChange(of: syncEnabled, perform: handleSyncToggle)
        .onChange(of: coordinator.manualSyncState) { state in
            guard let message = state.announcement else { return }
            SyncSettingsAccessibilityAnnouncement.post(message)
        }
        .confirmationDialog(
            "Remove Credentials from iCloud Keychain?",
            isPresented: $isConfirmingCredentialRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from iCloud Keychain", role: .destructive) {
                _ = coordinator.removeCredentialsFromICloud()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Credentials remain on this device. If you enable sync again, VVTerm will store them in iCloud Keychain again.")
        }
    }

    private var syncSection: some View {
        Section {
            Toggle("Enable iCloud Sync", isOn: $syncEnabled)

            VStack(alignment: .leading, spacing: 5) {
                syncStatusLabel

                if let date = coordinator.lastSuccessfulSyncDate {
                    HStack(spacing: 4) {
                        Text("Last Successful Sync")
                        Text(date, style: .relative)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vvterm.settings.sync.lastSuccessful.value")
                } else {
                    Text("Not Yet")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vvterm.settings.sync.lastSuccessful.empty")
                }

                if coordinator.cloudState.pendingOperationCount > 0 {
                    Text(pendingChangesText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vvterm.settings.sync.pendingChanges")
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)

            if syncEnabled && coordinator.canSyncNow {
                syncNowButton
                    .accessibilityIdentifier("vvterm.settings.sync.syncNow.primary")
            }

        } footer: {
            Text("Turning off sync keeps your data on this device. Existing data in iCloud is not deleted.")
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Label(
                "Workspaces, servers, settings, credentials, and SSH keys sync with iCloud.",
                systemImage: "icloud"
            )
            .accessibilityIdentifier("vvterm.settings.sync.data.synced")
            Label(
                "Active sessions and device data stay on this device.",
                systemImage: "iphone"
            )
            .accessibilityIdentifier("vvterm.settings.sync.data.local")
        }
    }

    private func troubleshootingSection(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)

            if syncEnabled && !coordinator.canSyncNow {
                Button {
                    Task { await coordinator.checkICloudStatus() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.manualSyncState == .running)
            }
        } header: {
            Text("Troubleshooting")
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                copyDiagnosticsButton

                if !syncEnabled {
                    Button(role: .destructive) {
                        isConfirmingCredentialRemoval = true
                    } label: {
                        Label("Remove Credentials from iCloud Keychain", systemImage: "key.slash")
                    }
                    .accessibilityIdentifier("vvterm.settings.sync.removeCredentials")
                }
            }
            .accessibilityIdentifier("vvterm.settings.sync.advanced")
        }
    }

    private var syncNowButton: some View {
        Button {
            Task { await coordinator.syncNow() }
        } label: {
            if coordinator.manualSyncState == .running {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing")
                }
            } else {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(coordinator.manualSyncState == .running)
    }

    private var copyDiagnosticsButton: some View {
        Button {
            Clipboard.copy(coordinator.diagnostics.text)
        } label: {
            Label("Copy Sync Diagnostics", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("vvterm.settings.sync.copyDiagnostics")
    }

    @ViewBuilder
    private var syncStatusLabel: some View {
        Group {
            switch coordinator.userState {
            case .upToDate:
                Label("Up to Date", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .syncing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing")
                }
            case .waitingForNetwork:
                Label("Waiting for Network", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            case .signInToICloud:
                Label("Sign In to iCloud", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            case .needsAttention:
                Label("Sync Needs Attention", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .disabled:
                Label("Sync Disabled", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body.weight(.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sync Status")
        .accessibilityValue(coordinator.userState.title)
        .accessibilityIdentifier("vvterm.settings.sync.status")
    }

    private var attentionMessage: String? {
        credentialFailureText ?? coordinator.userState.recoveryGuidance
    }

    private var pendingChangesText: String {
        let count = coordinator.cloudState.pendingOperationCount
        let format = count == 1
            ? String(localized: "%lld change will sync later.")
            : String(localized: "%lld changes will sync later.")
        return String(format: format, Int64(count))
    }

    private var credentialFailureText: String? {
        switch coordinator.credentialFailure {
        case .toggle:
            String(localized: "Credentials could not be copied. Existing credentials were kept.")
        case .sync:
            String(localized: "Credentials and SSH keys need attention. App data may still be up to date.")
        case .removal:
            String(localized: "Credentials could not be removed from iCloud Keychain. Existing credentials were kept.")
        case nil:
            nil
        }
    }

    private func handleSyncToggle(_ enabled: Bool) {
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
            Task { await coordinator.syncNow() }
        }
    }

}
