import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject private var coordinator: SyncSettingsCoordinator
    @State private var syncEnabled = SyncSettings.isEnabled
    @State private var ignoresNextSyncToggleChange = false
    @State private var isShowingSyncDetails = false

    var body: some View {
        Form {
            statusHeroSection
            syncToggleSection
            if let attentionMessage {
                troubleshootingSection(message: attentionMessage)
            }
            syncedDataSection
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
        .sheet(isPresented: $isShowingSyncDetails) {
            SyncSettingsDetailsSheet(
                summary: coordinator.contentSummary,
                syncEnabled: syncEnabled,
                lastSuccessfulSyncDate: coordinator.lastSuccessfulSyncDate,
                pendingChangeCount: coordinator.cloudState.pendingOperationCount,
                lastError: coordinator.lastError,
                diagnostics: coordinator.diagnostics.text,
                removeCredentialsFromICloud: {
                    _ = coordinator.removeCredentialsFromICloud()
                }
            )
        }
    }

    private var statusHeroSection: some View {
        Section {
            SyncSettingsStatusHero(
                state: coordinator.userState,
                lastSuccessfulSyncDate: coordinator.lastSuccessfulSyncDate,
                primaryAction: primaryAction,
                onPrimaryAction: handlePrimaryAction
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }

    private var syncToggleSection: some View {
        Section {
            Toggle("Sync with iCloud", isOn: $syncEnabled)
                .accessibilityIdentifier("vvterm.settings.sync.toggle")
        }
    }

    private var syncedDataSection: some View {
        Section {
            SyncSettingsSummaryRow(
                title: "App Data",
                systemImage: "externaldrive.fill",
                summary: coordinator.contentSummary.appDataSummaryText
            )
            .accessibilityIdentifier("vvterm.settings.sync.data.app")

            SyncSettingsSummaryRow(
                title: "Credentials",
                systemImage: "key.horizontal.fill",
                summary: coordinator.contentSummary.credentialSummaryText
            )
            .accessibilityIdentifier("vvterm.settings.sync.data.credentials")
        } header: {
            HStack {
                Text(syncedDataHeaderTitle)
                Spacer()
                Button {
                    isShowingSyncDetails = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show iCloud Sync Details")
                .accessibilityIdentifier("vvterm.settings.sync.detailsButton")
            }
        }
    }

    private func troubleshootingSection(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vvterm.settings.sync.troubleshooting")
        }
    }

    private var syncedDataHeaderTitle: LocalizedStringResource {
        syncEnabled ? "Synced with iCloud" : "Stored on This Device"
    }

    private var primaryAction: SyncSettingsPrimaryAction? {
        guard syncEnabled else { return nil }
        if coordinator.manualSyncState == .running {
            return .syncing
        }
        if coordinator.canSyncNow {
            return attentionMessage == nil ? .syncNow : .tryAgain
        }
        return attentionMessage == nil ? nil : .checkAgain
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
