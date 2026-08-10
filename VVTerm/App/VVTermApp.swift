//
//  VVTermApp.swift
//  VVTerm
//

import SwiftUI
#if os(iOS)
import WidgetKit
#endif

@main
struct VVTermApp: App {
    init() {
        let appLockManager = AppLockManager()
        let cloudKitSyncCoordinator = CloudKitSyncLiveComposition.makeLiveCoordinator()
        let serverManager = ServerManager(
            dependencies: .live(
                actionAuthorizer: appLockManager,
                syncRepository: cloudKitSyncCoordinator
            )
        )
        let engagementTracker = EngagementTracker(dependencies: .live)
        let tabManager = TerminalTabManagerLiveComposition.makeManager(
            appLockManager: appLockManager,
            serverManager: serverManager,
            engagementTracker: engagementTracker
        )
        let analyticsTracker = AnalyticsTracker.shared
        let storeManager = StoreManager(
            client: AppStoreKitClient(),
            effects: .live(
                analytics: analyticsTracker,
                engagementTracker: engagementTracker
            )
        )
        let terminalThemeManager = TerminalThemeManager(
            dependencies: .live(mutationQueue: cloudKitSyncCoordinator)
        )
        let terminalAccessoryPreferencesManager = TerminalAccessoryPreferencesManager(
            dependencies: .live(mutationQueue: cloudKitSyncCoordinator)
        )
        let statsPreferencesStore = PreferencesStore(
            dependencies: .live(mutationQueue: cloudKitSyncCoordinator)
        )
        let serverVolumeVisibilityStore = ServerVolumeVisibilityStore.live
        let viewTabConfigurationManager = ViewTabConfigurationManager(defaults: .standard)
        let cloudKitManager = CloudKitManager.shared
        let keychainManager = KeychainManager.shared
        let knownHostsManager = KnownHostsManager.shared
        let analyticsOptOutAction = AnalyticsOptOutAction(
            emitAnalyticsDisabled: {
                analyticsTracker.trackAnalyticsDisabled()
            }
        )
        let onWelcomeCompleted: @MainActor () -> Void = {
            analyticsTracker.trackWelcomeCompleted()
        }
        let syncSettingsCoordinator = SyncSettingsLiveComposition.makeCoordinator(
            cloudKit: cloudKitManager,
            keychain: keychainManager,
            serverManager: serverManager,
            terminalAccessory: terminalAccessoryPreferencesManager
        )
        let sshKeySettingsCoordinator = SSHKeySettingsLiveComposition.makeCoordinator(
            keychain: keychainManager
        )
        let knownHostSettingsCoordinator = KnownHostSettingsLiveComposition.makeCoordinator(
            knownHosts: knownHostsManager
        )
        let networkMonitor = NetworkMonitor.shared
        #if os(iOS)
        let liveActivityManager = LiveActivityManager.shared
        let appLifecycleDependencies = AppLifecycleDependencies(
            subscribeToRemoteChanges: {
                await cloudKitManager.subscribeToChanges()
            },
            refreshNetwork: {
                networkMonitor.refreshCurrentPath()
            },
            endLiveActivitiesForApplicationTermination: {
                liveActivityManager.endForApplicationTermination()
            }
        )
        #else
        let appLifecycleDependencies = AppLifecycleDependencies(
            subscribeToRemoteChanges: {
                await cloudKitManager.subscribeToChanges()
            },
            refreshNetwork: {
                networkMonitor.refreshCurrentPath()
            }
        )
        #endif
        #if os(iOS)
        self.analyticsOptOutAction = analyticsOptOutAction
        #endif
        self.onWelcomeCompleted = onWelcomeCompleted
        _tabManager = StateObject(wrappedValue: tabManager)
        _storeManager = StateObject(wrappedValue: storeManager)
        _appLockManager = StateObject(wrappedValue: appLockManager)
        _serverManager = StateObject(wrappedValue: serverManager)
        _engagementTracker = StateObject(wrappedValue: engagementTracker)
        _terminalThemeManager = StateObject(wrappedValue: terminalThemeManager)
        _terminalAccessoryPreferencesManager = StateObject(
            wrappedValue: terminalAccessoryPreferencesManager
        )
        _statsPreferencesStore = StateObject(wrappedValue: statsPreferencesStore)
        _serverVolumeVisibilityStore = StateObject(wrappedValue: serverVolumeVisibilityStore)
        statsSecurityApprovalActions = Self.makeStatsSecurityApprovalActions(
            appLockManager: appLockManager
        )
        _viewTabConfigurationManager = StateObject(
            wrappedValue: viewTabConfigurationManager
        )
        _syncSettingsCoordinator = StateObject(wrappedValue: syncSettingsCoordinator)
        _sshKeySettingsCoordinator = StateObject(wrappedValue: sshKeySettingsCoordinator)
        _knownHostSettingsCoordinator = StateObject(wrappedValue: knownHostSettingsCoordinator)
        _remoteFileBrowserStore = StateObject(
            wrappedValue: Self.makeRemoteFileBrowserStore(
                tabManager: tabManager,
                serverManager: serverManager
            )
        )
        #if os(macOS)
        settingsWindowPresenter = SettingsWindowPresenter(
            appLockManager: appLockManager,
            serverManager: serverManager,
            terminalThemeManager: terminalThemeManager,
            terminalAccessoryPreferencesManager: terminalAccessoryPreferencesManager,
            viewTabConfigurationManager: viewTabConfigurationManager,
            storeManager: storeManager,
            statsPreferencesStore: statsPreferencesStore,
            syncSettingsCoordinator: syncSettingsCoordinator,
            sshKeySettingsCoordinator: sshKeySettingsCoordinator,
            knownHostSettingsCoordinator: knownHostSettingsCoordinator,
            analyticsOptOutAction: analyticsOptOutAction
        )
        #endif
        appDelegate.configure(
            tabManager: tabManager,
            serverManager: serverManager,
            appLockManager: appLockManager,
            lifecycleDependencies: appLifecycleDependencies
        )
        #if os(macOS)
        MacConnectionToolbarController.shared.configure(tabManager: tabManager)
        #endif
        storeManager.start()

        TerminalDefaults.applyIfNeeded()
        #if os(iOS)
        VVTermLauncherWidgetRefresh.refreshIfNeeded()
        analyticsTracker.prepareAppleAdsAttribution()
        #endif
    }

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    @StateObject private var ghosttyApp = Ghostty.App(autoStart: false)
    #if os(iOS)
    @StateObject private var screenAwakeCoordinator = TerminalScreenAwakeCoordinator()
    private let analyticsOptOutAction: AnalyticsOptOutAction
    #endif
    @StateObject private var appLockManager: AppLockManager
    @StateObject private var serverManager: ServerManager
    @StateObject private var engagementTracker: EngagementTracker
    @StateObject private var tabManager: TerminalTabManager
    @StateObject private var storeManager: StoreManager
    @StateObject private var remoteFileTabManager = RemoteFileTabManager()
    @StateObject private var remoteFileBrowserStore: RemoteFileBrowserStore
    @StateObject private var terminalThemeManager: TerminalThemeManager
    @StateObject private var terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
    @StateObject private var statsPreferencesStore: PreferencesStore
    @StateObject private var serverVolumeVisibilityStore: ServerVolumeVisibilityStore
    @StateObject private var viewTabConfigurationManager: ViewTabConfigurationManager
    @StateObject private var syncSettingsCoordinator: SyncSettingsCoordinator
    @StateObject private var sshKeySettingsCoordinator: SSHKeySettingsCoordinator
    @StateObject private var knownHostSettingsCoordinator: KnownHostSettingsCoordinator
    private let onWelcomeCompleted: @MainActor () -> Void
    private let statsSecurityApprovalActions: ServerStatsSecurityApprovalActions
    #if os(macOS)
    private let settingsWindowPresenter: SettingsWindowPresenter
    #endif

    // Welcome screen flag
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    // App language
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false

    // Terminal settings to watch for changes
    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = TerminalDefaults.defaultFontName
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.cursorStyleKey) private var terminalCursorStyle = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var terminalCursorBlink = TerminalDefaults.defaultCursorBlink
    #if os(macOS)
    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var terminalOptionAsAltMode = TerminalOptionAsAltMode.none.rawValue
    #endif
    @AppStorage(TerminalRemoteClipboardReadPolicy.userDefaultsKey)
    private var remoteClipboardReadPolicy = TerminalRemoteClipboardReadPolicy.defaultValue.rawValue

    private var terminalOptionAsAltReloadToken: String {
        #if os(macOS)
        terminalOptionAsAltMode
        #else
        ""
        #endif
    }

    private var statsDependencies: ServerStatsScreenDependencies {
        ServerStatsScreenDependencies(
            makeCollector: { ServerStatsCollector() },
            preferencesStore: statsPreferencesStore,
            volumeVisibilityStore: serverVolumeVisibilityStore,
            securityApprovalActions: statsSecurityApprovalActions
        )
    }

    #if os(iOS) && DEBUG
    private var usesTerminalKeyboardUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-keyboard-harness")
    }

    private var usesTerminalSplitKeyboardUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-terminal-split-keyboard-harness"
        )
    }

    private var usesTerminalReconnectUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-reconnect-harness")
    }

    private var usesTerminalScreenAwakeUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-screen-awake-harness")
    }

    private var usesNoticePresentationUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notice-harness")
    }

    private var usesStatsStorageUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-stats-storage-harness")
    }

    private var usesStatsCardsLayoutUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-stats-cards-layout-harness")
    }

    private var usesTerminalZenModeUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-zen-mode-harness")
    }
    #endif

    #if os(macOS)
    @ViewBuilder
    private var macOSRootContent: some View {
        #if DEBUG
        if Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-mac-terminal-recovery-harness"
        ) {
            MacTerminalRecoveryUITestHarness(
                simulatesSuccess: !Foundation.ProcessInfo.processInfo.arguments.contains(
                    "--vvterm-ui-test-mac-terminal-recovery-failure"
                )
            )
        } else {
            macOSAppContent
        }
        #else
        macOSAppContent
        #endif
    }

    private var macOSAppContent: some View {
        ContentView(
            serverManager: serverManager,
            engagementTracker: engagementTracker,
            tabManager: tabManager,
            fileTabs: remoteFileTabManager,
            fileBrowser: remoteFileBrowserStore,
            statsDependencies: statsDependencies,
            onOpenSettings: { settingsWindowPresenter.show() }
        )
            .environmentObject(ghosttyApp)
            .environmentObject(terminalThemeManager)
            .environmentObject(terminalAccessoryPreferencesManager)
            .modifier(AppearanceModifier())
            .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalCursorStyle)\(terminalCursorBlink)\(terminalOptionAsAltReloadToken)\(remoteClipboardReadPolicy)") {
                ghosttyApp.reloadConfig()
            }
            .sheet(isPresented: .init(
                get: { !hasSeenWelcome },
                set: { if !$0 { hasSeenWelcome = true } }
            )) {
                WelcomeView(
                    hasSeenWelcome: $hasSeenWelcome,
                    onCompleted: onWelcomeCompleted
                )
                    .adaptiveSoftScrollEdges()
            }
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private var iOSRootContent: some View {
        #if DEBUG
        if usesNoticePresentationUITestHarness {
            NoticePresentationUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesStatsCardsLayoutUITestHarness {
            StatsCardsLayoutUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalZenModeUITestHarness {
            TerminalZenModeUITestHarness()
                .environmentObject(ghosttyApp)
                .modifier(AppearanceModifier())
        } else if usesStatsStorageUITestHarness {
            StatsStorageUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalScreenAwakeUITestHarness {
            TerminalScreenAwakeUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalReconnectUITestHarness {
            TerminalReconnectUITestHarness(
                tabManager: tabManager,
                serverManager: serverManager,
                engagementTracker: engagementTracker,
                statsDependencies: statsDependencies
            )
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else if usesTerminalSplitKeyboardUITestHarness {
            TerminalSplitKeyboardUITestHarness(tabManager: tabManager)
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else if usesTerminalKeyboardUITestHarness {
            TerminalKeyboardUITestHarness(tabManager: tabManager)
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else {
            iOSAppContent
        }
        #else
        iOSAppContent
        #endif
    }

    private var iOSAppContent: some View {
        iOSContentView(
            serverManager: serverManager,
            engagementTracker: engagementTracker,
            tabManager: tabManager,
            fileTabs: remoteFileTabManager,
            fileBrowser: remoteFileBrowserStore,
            statsDependencies: statsDependencies,
            analyticsOptOutAction: analyticsOptOutAction
        )
            .environmentObject(ghosttyApp)
            .environmentObject(terminalThemeManager)
            .environmentObject(terminalAccessoryPreferencesManager)
            .modifier(AppearanceModifier())
            .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalCursorStyle)\(terminalCursorBlink)\(terminalOptionAsAltReloadToken)\(remoteClipboardReadPolicy)") {
                ghosttyApp.reloadConfig()
            }
            .sheet(isPresented: .init(
                get: { !hasSeenWelcome },
                set: { if !$0 { hasSeenWelcome = true } }
            )) {
                WelcomeView(
                    hasSeenWelcome: $hasSeenWelcome,
                    onCompleted: onWelcomeCompleted
                )
                    .adaptiveSoftScrollEdges()
            }
    }
    #endif

    var body: some Scene {
        WindowGroup("", id: "main") {
            let appLocale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
            AppLockContainer {
                NoticeAppHost {
                    Group {
                        #if os(iOS)
                        iOSRootContent
                            .environmentObject(screenAwakeCoordinator)
                        #else
                        macOSRootContent
                        #endif
                    }
                    .adaptiveSoftScrollEdges()
                    .environment(\.locale, appLocale)
                    .environment(\.privacyModeEnabled, privacyModeEnabled)
                    .onAppear {
                        AppLanguage.applySelection(appLanguage)
                        serverManager.handleAppLanguageChange()
                    }
                    .onChange(of: appLanguage) { newValue in
                        AppLanguage.applySelection(newValue)
                        serverManager.handleAppLanguageChange()
                    }
                }
            }
            .environmentObject(appLockManager)
            .environmentObject(serverManager)
            .environmentObject(storeManager)
            .environmentObject(viewTabConfigurationManager)
            .environmentObject(syncSettingsCoordinator)
            .environmentObject(sshKeySettingsCoordinator)
            .environmentObject(knownHostSettingsCoordinator)
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            VVTermCommands(settingsWindowPresenter: settingsWindowPresenter)
        }
        #endif
    }
}

#if os(iOS)
private enum VVTermLauncherWidgetRefresh {
    private static let renderingRevision = 1
    private static let renderingRevisionKey = "launcherWidgetRenderingRevision"

    static func refreshIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: renderingRevisionKey) < renderingRevision else { return }

        WidgetCenter.shared.reloadTimelines(ofKind: VVTermWidgetKind.launcher)
        defaults.set(renderingRevision, forKey: renderingRevisionKey)
    }
}
#endif

extension VVTermApp {
    static func makeStatsSecurityApprovalActions(
        appLockManager: AppLockManager
    ) -> ServerStatsSecurityApprovalActions {
        ServerStatsSecurityApprovalActions(
            approve: { request, server in
                switch request {
                case .credentialEndpoint(let serverID):
                    guard serverID == server.id else { return .failed(.expired) }
                    guard await appLockManager.authorizeProtectedServerAction(
                        server,
                        action: .approveCredentialEndpoint
                    ) else {
                        return .failed(.cancelled)
                    }
                    do {
                        try KeychainManager.shared.approveCredentialUse(for: server)
                        return .approved
                    } catch {
                        return .failed(.unavailable)
                    }
                case .hostKey(let challenge):
                    return KnownHostsManager.shared.approve(challenge)
                        ? .approved
                        : .failed(.expired)
                }
            },
            reject: { request in
                guard case .hostKey(let challenge) = request else { return }
                KnownHostsManager.shared.reject(challenge)
            }
        )
    }

    static func makeRemoteFileBrowserStore(
        tabManager: TerminalTabManager,
        serverManager: ServerManager,
        defaults: UserDefaults = .standard
    ) -> RemoteFileBrowserStore {
        let adapter = SSHSFTPAdapter(borrowedClientProvider: { serverId in
            tabManager.sharedStatsClient(for: serverId)
        })

        return RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: adapter,
            serverProvider: { serverId in
                serverManager.servers.first { $0.id == serverId }
            },
            workingDirectoryProvider: { serverId in
                tabManager.workingDirectoryCandidate(for: serverId)
            }
        )
    }
}
