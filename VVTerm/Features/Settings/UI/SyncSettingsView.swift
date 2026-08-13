import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject private var coordinator: SyncSettingsCoordinator
    @State private var syncEnabled = SyncSettings.isEnabled
    @State private var ignoresNextSyncToggleChange = false
    @State private var isConfirmingCredentialRemoval = false

    var body: some View {
        Form {
            statusHeroSection
            syncToggleSection
            if let attentionMessage {
                troubleshootingSection(message: attentionMessage)
            }
            syncedDataSection
            deviceDataSection
            if showsPrimaryAction {
                primaryActionSection
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

    private var statusHeroSection: some View {
        Section {
            SyncSettingsStatusHero(
                state: coordinator.userState,
                lastSuccessfulSyncDate: coordinator.lastSuccessfulSyncDate
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }

    private var syncToggleSection: some View {
        Section {
            Toggle(isOn: $syncEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync with iCloud")
                    if syncEnabled {
                        Text("Keep your setup on all devices.")
                    } else {
                        Text("Use data stored on this device.")
                    }
                }
            }
            .accessibilityIdentifier("vvterm.settings.sync.toggle")
        } footer: {
            if !syncEnabled {
                Text("Existing iCloud data is not deleted.")
            }
        }
    }

    private var syncedDataSection: some View {
        Section {
            SyncSettingsDataRow(
                title: "Servers & Settings",
                systemImage: "server.rack",
                status: coordinator.userState.appDataStatusTitle
            )
            .accessibilityIdentifier("vvterm.settings.sync.data.app")

            SyncSettingsDataRow(
                title: "Passwords & SSH Keys",
                systemImage: "key.horizontal.fill",
                status: coordinator.credentialState.statusTitle
            )
            .accessibilityIdentifier("vvterm.settings.sync.data.credentials")
        } header: {
            Text(syncedDataHeaderTitle)
        }
    }

    private var deviceDataSection: some View {
        Section("On This Device") {
            SyncSettingsDataRow(
                title: "Active Sessions",
                systemImage: "terminal",
                status: "Device Only"
            )
            .accessibilityIdentifier("vvterm.settings.sync.data.sessions")
        }
    }

    private func troubleshootingSection(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vvterm.settings.sync.troubleshooting")
        }
    }

    private var primaryActionSection: some View {
        Section {
            Button(action: handlePrimaryAction) {
                if coordinator.manualSyncState == .running {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Syncing")
                    }
                } else if coordinator.canSyncNow {
                    Label(
                        primaryActionTitle,
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                } else {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(coordinator.manualSyncState == .running)
            .accessibilityIdentifier("vvterm.settings.sync.action.primary")
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                if let date = coordinator.lastSuccessfulSyncDate {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last Successful Sync")
                        Text(
                            date,
                            format: .dateTime.year().month().day().hour().minute()
                        )
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("vvterm.settings.sync.advanced.lastSuccessful")
                }

                if coordinator.cloudState.pendingOperationCount > 0 {
                    HStack {
                        Text("Pending Changes")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(coordinator.cloudState.pendingOperationCount, format: .number)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("vvterm.settings.sync.advanced.pendingChanges")
                }

                if let lastError = coordinator.lastError {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last Sync Error")
                        Text(lastError.category.title)
                            .foregroundStyle(.secondary)
                        Text(
                            lastError.date,
                            format: .dateTime.year().month().day().hour().minute()
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("vvterm.settings.sync.advanced.lastError")
                }

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

    private var copyDiagnosticsButton: some View {
        Button {
            Clipboard.copy(coordinator.diagnostics.text)
        } label: {
            Label("Copy Sync Diagnostics", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("vvterm.settings.sync.copyDiagnostics")
    }

    private var showsPrimaryAction: Bool {
        syncEnabled && (
            coordinator.manualSyncState == .running
                || coordinator.canSyncNow
                || attentionMessage != nil
        )
    }

    private var syncedDataHeaderTitle: LocalizedStringResource {
        syncEnabled ? "Synced with iCloud" : "Data on This Device"
    }

    private var primaryActionTitle: LocalizedStringResource {
        attentionMessage == nil ? "Sync Now" : "Try Again"
    }

    private var attentionMessage: String? {
        credentialFailureText ?? coordinator.userState.recoveryGuidance
    }

    private var credentialFailureText: String? {
        switch coordinator.credentialFailure {
        case .toggle:
            String(localized: "Credentials could not be copied. Nothing was removed.")
        case .sync:
            String(localized: "Credentials and SSH keys need attention.")
        case .removal:
            String(localized: "Credentials could not be removed. Nothing was changed.")
        case nil:
            nil
        }
    }

    private func handlePrimaryAction() {
        if coordinator.canSyncNow {
            Task { await coordinator.syncNow() }
        } else {
            Task { await coordinator.checkICloudStatus() }
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

private struct SyncSettingsDataRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let status: LocalizedStringResource

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(status)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
