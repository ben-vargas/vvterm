import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject private var coordinator: SyncSettingsCoordinator
    @EnvironmentObject private var serverManager: ServerManager
    @EnvironmentObject private var terminalAccessory: TerminalAccessoryPreferencesManager
    @State private var syncEnabled = SyncSettings.isEnabled
    @State private var ignoresNextSyncToggleChange = false
    @State private var isShowingTroubleshooting = false
    @State private var isConfirmingCredentialRemoval = false

    var body: some View {
        Form {
            iCloudSyncSection
            syncServicesSection
            includedInSyncSection
            notSyncedSection
            if showsTroubleshooting {
                troubleshootingSection
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

    private var iCloudSyncSection: some View {
        Section {
            Toggle("Enable iCloud Sync", isOn: $syncEnabled)

            LabeledContent("Status") {
                syncStatusLabel
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync Status")
            .accessibilityValue(coordinator.userState.title)
            .accessibilityIdentifier("vvterm.settings.sync.status")

            LabeledContent("Last Successful Sync") {
                if let date = coordinator.lastSuccessfulSyncDate {
                    Text(date, style: .relative)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vvterm.settings.sync.lastSuccessful.value")
                } else {
                    Text("Not Yet")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vvterm.settings.sync.lastSuccessful.empty")
                }
            }

            if coordinator.cloudState.pendingOperationCount > 0 {
                Text(pendingChangesText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vvterm.settings.sync.pendingChanges")
            }

            if syncEnabled && coordinator.canSyncNow {
                syncNowButton
                    .accessibilityIdentifier("vvterm.settings.sync.syncNow.primary")
            }

            if let credentialFailureText {
                Label(credentialFailureText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("Turning off sync keeps your data on this device. Existing data in iCloud is not deleted.")
        }
    }

    private var syncServicesSection: some View {
        Section("Sync Services") {
            LabeledContent {
                Text(coordinator.userState.appDataServiceTitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("App Data — iCloud", systemImage: "icloud")
            }
            .accessibilityIdentifier("vvterm.settings.sync.service.appData")

            LabeledContent {
                Text(coordinator.credentialState.title)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("Credentials and SSH Keys — iCloud Keychain", systemImage: "key.icloud")
            }
            .accessibilityIdentifier("vvterm.settings.sync.service.credentials")
        }
    }

    private var includedInSyncSection: some View {
        Section("Included in Sync") {
            dynamicSyncContractRow(
                title: workspaceCountText,
                icon: "folder",
                identifier: "vvterm.settings.sync.localCount.workspaces"
            )
            dynamicSyncContractRow(
                title: serverCountText,
                icon: "server.rack",
                identifier: "vvterm.settings.sync.localCount.servers"
            )
            syncContractRow("Server credentials", icon: "lock")
            syncContractRow("Reusable SSH keys", icon: "key")
            syncContractRow(
                "Custom terminal themes and theme selection",
                icon: "paintpalette"
            )
            dynamicSyncContractRow(
                title: accessoryContextText,
                icon: "keyboard",
                identifier: "vvterm.settings.sync.localCount.accessories"
            )
            syncContractRow("Stats appearance preferences", icon: "chart.bar")
        }
    }

    private var notSyncedSection: some View {
        Section("Not Synced") {
            syncContractRow("Open terminal tabs and active sessions", icon: "terminal")
            syncContractRow("Trusted SSH host fingerprints", icon: "checkmark.shield")
            syncContractRow("Downloaded transcription models", icon: "waveform")
            syncContractRow(
                "Device identity, session resume data, temporary data, and caches",
                icon: "iphone"
            )
        }
    }

    private var troubleshootingSection: some View {
        Section {
            Text(coordinator.userState.recoveryGuidance)
                .foregroundStyle(.secondary)

            if syncEnabled && coordinator.canSyncNow {
                syncNowButton
                    .accessibilityIdentifier("vvterm.settings.sync.syncNow.troubleshooting")
            }

            Button {
                Task { await coordinator.checkICloudStatus() }
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .disabled(coordinator.manualSyncState == .running)

            copyDiagnosticsButton
        } header: {
            Text("Troubleshooting")
        }
    }

    private var advancedSection: some View {
        Section {
            syncNowButton
                .disabled(!syncEnabled || !coordinator.canSyncNow)
                .accessibilityIdentifier("vvterm.settings.sync.syncNow.advanced")

            Button {
                Task { await coordinator.checkICloudStatus() }
            } label: {
                Label("Check iCloud Status", systemImage: "checkmark.icloud")
            }
            .disabled(!syncEnabled || coordinator.manualSyncState == .running)

            copyDiagnosticsButton

            Button {
                isShowingTroubleshooting.toggle()
            } label: {
                if isShowingTroubleshooting {
                    Label("Hide Sync Help", systemImage: "questionmark.circle")
                } else {
                    Label("Show Sync Help", systemImage: "questionmark.circle")
                }
            }

            Button(role: .destructive) {
                isConfirmingCredentialRemoval = true
            } label: {
                Label("Remove Credentials from iCloud Keychain", systemImage: "key.slash")
            }
            .disabled(syncEnabled)
            .accessibilityIdentifier("vvterm.settings.sync.removeCredentials")
        } header: {
            Text("Advanced")
        } footer: {
            if syncEnabled {
                Text("Turn off iCloud Sync before removing credentials from iCloud Keychain.")
            }
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

    private var showsTroubleshooting: Bool {
        isShowingTroubleshooting || coordinator.userState.needsTroubleshooting
    }

    private var pendingChangesText: String {
        let count = coordinator.cloudState.pendingOperationCount
        let format = count == 1
            ? String(localized: "%lld change will sync later.")
            : String(localized: "%lld changes will sync later.")
        return String(format: format, Int64(count))
    }

    private var accessoryContextText: String {
        let itemCount = terminalAccessory.profile.layout.activeItems.count
        let actionCount = terminalAccessory.customActions.count
        return String(
            format: String(localized: "Keyboard accessory layout and custom actions (%lld items and %lld actions on this device)"),
            Int64(itemCount),
            Int64(actionCount)
        )
    }

    private var workspaceCountText: String {
        let count = serverManager.workspaces.count
        let format = count == 1
            ? String(localized: "%lld workspace on this device. Included in iCloud Sync.")
            : String(localized: "%lld workspaces on this device. Included in iCloud Sync.")
        return String(format: format, Int64(count))
    }

    private var serverCountText: String {
        let count = serverManager.servers.count
        let format = count == 1
            ? String(localized: "%lld server on this device. Included in iCloud Sync.")
            : String(localized: "%lld servers on this device. Included in iCloud Sync.")
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

    private func syncContractRow(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func dynamicSyncContractRow(
        title: String,
        icon: String,
        identifier: String
    ) -> some View {
        Label(title, systemImage: icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
    }
}
