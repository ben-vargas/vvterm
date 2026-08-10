//
//  SettingsView.swift
//  VVTerm
//

import SwiftUI
#if os(macOS)
import AppKit

private extension View {
    @ViewBuilder
    func removingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}
#endif

// MARK: - Settings Selection

enum SettingsSelection: Hashable {
    case pro
    case general
    case terminal
    case transcription
    case keychain
    case sync
    case about
}

// MARK: - Settings View

struct SettingsView: View {
    let statsPreferencesStore: PreferencesStore
    let voiceModelManagers: VoiceSettingsModelManagerOwner
    let analyticsOptOutAction: AnalyticsOptOutAction

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = TerminalDefaults.defaultFontName
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize

    @State private var selection: SettingsSelection? = .pro
    @EnvironmentObject private var storeManager: StoreManager

    private var hasConfirmedProAccess: Bool {
        storeManager.accessState == .pro
    }

    private var storeStatusLabel: String {
        switch storeManager.accessState {
        case .checking:
            String(localized: "Checking...")
        case .free:
            String(localized: "FREE_PLAN")
        case .pro:
            String(localized: "PRO")
        }
    }

    private var storeSummary: String {
        switch storeManager.accessState {
        case .checking:
            String(localized: "Checking...")
        case .free:
            String(localized: "Upgrade for unlimited features")
        case .pro:
            String(localized: "Manage subscription")
        }
    }

    private var storeNavigationSubtitle: String {
        switch storeManager.accessState {
        case .checking:
            String(localized: "Checking...")
        case .free:
            String(localized: "Upgrade for unlimited features")
        case .pro:
            String(localized: "Manage your subscription")
        }
    }

    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: $selection) {
                // Pro at top (not part of selection - has its own styling)
                Button {
                    selection = .pro
                } label: {
                    proNavigationRow
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Divider()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                settingsRow("General", icon: "gear", tag: .general)
                settingsRow("Terminal", icon: "terminal", tag: .terminal)
                settingsRow("Transcription", icon: "waveform", tag: .transcription)
                settingsRow("SSH Keys", icon: "key", tag: .keychain)
                settingsRow("Sync", icon: "icloud", tag: .sync)
                settingsRow("About", icon: "info.circle", tag: .about)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 240, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(240)
            .removingSidebarToggle()
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .principal) { Text("") }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 500)
        #else
        NavigationStack {
            List {
                // Pro card at top
                Section {
                    NavigationLink {
                        ProSettingsView()
                            .navigationTitle("VVTerm Pro")
                            .navigationBarTitleDisplayMode(.inline)
                            .adaptiveSoftScrollEdges()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [Color.orange, Color(red: 0.95, green: 0.5, blue: 0.2)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "sparkles")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("VVTerm Pro")
                                    .font(.headline)
                                Text(storeSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(storeStatusLabel)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(hasConfirmedProAccess ? .white : .primary.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(hasConfirmedProAccess
                                            ? Color.orange
                                            : Color.primary.opacity(0.12)
                                        )
                                )
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    NavigationLink {
                        GeneralSettingsView(
                            statsPreferencesStore: statsPreferencesStore,
                            analyticsOptOutAction: analyticsOptOutAction
                        )
                            .navigationTitle("General")
                            .navigationBarTitleDisplayMode(.inline)
                            .adaptiveSoftScrollEdges()
                    } label: {
                        Label("General", systemImage: "gear")
                    }

                    NavigationLink {
                        TerminalSettingsView(fontName: $terminalFontName, fontSize: $terminalFontSize)
                            .navigationTitle("Terminal")
                            .navigationBarTitleDisplayMode(.inline)
                            .adaptiveSoftScrollEdges()
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                    }

                    NavigationLink {
                        TranscriptionSettingsView(modelManagers: voiceModelManagers)
                            .navigationTitle("Transcription")
                            .navigationBarTitleDisplayMode(.inline)
                            .adaptiveSoftScrollEdges()
                    } label: {
                        Label("Transcription", systemImage: "waveform")
                    }

                    NavigationLink {
                        KeychainSettingsView()
                            .navigationTitle("SSH Keys")
                            .navigationBarTitleDisplayMode(.inline)
                            .adaptiveSoftScrollEdges()
                    } label: {
                        Label("SSH Keys", systemImage: "key")
                    }

                    NavigationLink {
                        SyncSettingsView()
                            .navigationTitle("Sync")
                            .navigationBarTitleDisplayMode(.inline)
                            .adaptiveSoftScrollEdges()
                    } label: {
                        Label("Sync", systemImage: "icloud")
                    }

                    NavigationLink {
                        AboutSettingsView()
                            .navigationTitle("About")
                            .navigationBarTitleDisplayMode(.inline)
                            .adaptiveSoftScrollEdges()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.root")
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .pro:
                            ProSettingsView()
                                .navigationTitle("VVTerm Pro")
                                .navigationSubtitle(storeNavigationSubtitle)
        case .general:
                            GeneralSettingsView(
                                statsPreferencesStore: statsPreferencesStore,
                                analyticsOptOutAction: analyticsOptOutAction
                            )
                                .navigationTitle("General")
                                .navigationSubtitle(String(localized: "Appearance and preferences"))
        case .terminal:
                            TerminalSettingsView(fontName: $terminalFontName, fontSize: $terminalFontSize)
                                .navigationTitle("Terminal")
                                .navigationSubtitle(String(localized: "Font, theme, and connection settings"))
        case .transcription:
                            TranscriptionSettingsView(modelManagers: voiceModelManagers)
                                .navigationTitle("Transcription")
                                .navigationSubtitle(String(localized: "Speech-to-text engine and models"))
        case .keychain:
                            KeychainSettingsView()
                                .navigationTitle("SSH Keys")
                                .navigationSubtitle(String(localized: "Manage stored SSH keys"))
        case .sync:
                            SyncSettingsView()
                                .navigationTitle("Sync")
                                .navigationSubtitle(String(localized: "iCloud sync and data management"))
        case .about:
                            AboutSettingsView()
                                .navigationTitle("About")
                                .navigationSubtitle(String(localized: "Version and links"))
        case .none:
                            ProSettingsView()
                                .navigationTitle("VVTerm Pro")
                                .navigationSubtitle(storeNavigationSubtitle)
        }
    }

    private var proNavigationRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.orange, Color(red: 0.95, green: 0.5, blue: 0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 24, height: 24)
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text("Premium")
                .fontWeight(.medium)

            Spacer()

            Text(storeStatusLabel)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hasConfirmedProAccess ? .white : .primary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(hasConfirmedProAccess
                            ? Color.orange
                            : Color.primary.opacity(0.12)
                        )
                )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func settingsRow(_ title: LocalizedStringKey, icon: String, tag: SettingsSelection) -> some View {
        Label(title, systemImage: icon)
            .tag(tag)
    }
    #endif
}

// MARK: - Preview

#Preview {
    let appLockManager = AppLockManager()
    let defaults = UserDefaults.standard
    let syncLifecycle = CloudKitSyncLifecycleDriver(
        defaults: defaults,
        notificationCenter: .default
    )
    let cloudKitSync = CloudKitSyncLiveComposition.makeLive(
        transport: CloudKitManager.shared,
        defaults: defaults,
        now: Date.init,
        makeID: UUID.init
    )
    let cloudKitSyncCoordinator = cloudKitSync.coordinator
    let serverManager = ServerManager(
        dependencies: .live(
            defaults: defaults,
            serverCloud: cloudKitSync.serverCloud,
            credentialRepository: KeychainManager.shared,
            knownHosts: KnownHostsManager.shared,
            freePlanTracker: AnalyticsTracker.shared,
            actionAuthorizer: appLockManager,
            syncRepository: cloudKitSyncCoordinator,
            defaultWorkspaceName: { "My Servers" },
            canonicalDefaultWorkspaceNames: { ["My Servers"] },
            now: Date.init,
            makeID: UUID.init
        ),
        startsAutomatically: false
    )
    let voiceSettingsStore = VoiceSettingsStore(
        persistence: UserDefaultsVoiceSettingsPersistence(defaults: defaults)
    )
    let voiceModelManagers = VoiceSettingsModelManagerOwner(
        settingsStore: voiceSettingsStore,
        makeManager: { kind, selectedModelID in
            MLXModelManager(
                kind: kind,
                selectedModelID: selectedModelID,
                storageRoot: MLXModelManager.modelsRoot,
                sessionLifecycle: .live,
                operations: .live
            )
        }
    )
    SettingsView(
        statsPreferencesStore: PreferencesStore(
            dependencies: .live(
                defaults: defaults,
                cloud: cloudKitSync.statsPreferencesCloud,
                mutationQueue: cloudKitSyncCoordinator,
                syncLifecycle: syncLifecycle,
                resolutionSource: cloudKitSync.statsPreferencesResolutions,
                writerID: DeviceIdentity.id,
                isSyncEnabled: { SyncSettings.isEnabled(in: defaults) },
                now: Date.init
            )
        ),
        voiceModelManagers: voiceModelManagers,
        analyticsOptOutAction: AnalyticsOptOutAction(emitAnalyticsDisabled: {})
    )
        .environmentObject(serverManager)
        .environmentObject(StoreManager(client: AppStoreKitClient(), effects: .none))
}
