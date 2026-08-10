//
//  VVTermApp.swift
//  VVTerm
//

import SwiftUI
#if os(iOS)
import UIKit
import WidgetKit
#elseif os(macOS)
import AppKit
#endif

@main
struct VVTermApp: App {
    init() {
        let defaults = UserDefaults.standard
        let notificationCenter = NotificationCenter.default
        let calendar = Calendar.current
        let now: () -> Date = Date.init
        let makeID: () -> UUID = UUID.init
        let defaultWorkspaceName: () -> String = {
            AppLanguage.localizedString(
                "My Servers",
                rawValue: defaults.string(forKey: AppLanguage.storageKey)
            )
        }
        let canonicalDefaultWorkspaceNames: () -> Set<String> = {
            AppLanguage.localizedValues(for: "My Servers")
        }
        let networkMonitor = NetworkMonitor.shared
        let analyticsTracker = AnalyticsTracker.shared
        let cloudKitManager = CloudKitManager.shared
        let keychainManager = KeychainManager.shared
        let knownHostsManager = KnownHostsManager.shared
        let connectionOperations = SSHConnectionOperationService.shared
        let liveActivityManager = LiveActivityManager.shared
        let remoteMosh = RemoteMoshManager.shared
        let remoteTmux = RemoteTmuxManager.shared
        let eternalTerminalResumeStore = EternalTerminalResumeStore.shared
        let moshResumeStore = MoshResumeStore.shared
        let terminalSurfaceStore = GhosttyTerminalSurfaceStore()
        let deviceID = DeviceIdentity.id
        let applicationIsActive: @MainActor () -> Bool = {
            #if os(iOS)
            UIApplication.shared.applicationState == .active
            #else
            NSApplication.shared.isActive
            #endif
        }
        let appLockManager = AppLockManager()
        let syncLifecycle = CloudKitSyncLifecycleDriver(
            defaults: defaults,
            notificationCenter: notificationCenter,
            now: now
        )
        let isSyncEnabled = { SyncSettings.isEnabled(in: defaults) }
        let cloudKitSync = CloudKitSyncLiveComposition.makeLive(
            transport: cloudKitManager,
            now: now
        )
        let cloudKitSyncCoordinator = cloudKitSync.coordinator
        let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory = {
            LocalSSHDiscoveryManager(
                dependencies: .live(
                    networkConnectionType: { networkMonitor.connectionType },
                    makeScanID: makeID
                )
            )
        }
        let serverManager = ServerManager(
            dependencies: .live(
                defaults: defaults,
                serverCloud: cloudKitSync.serverCloud,
                credentialRepository: keychainManager,
                knownHosts: knownHostsManager,
                freePlanTracker: analyticsTracker,
                actionAuthorizer: appLockManager,
                syncRepository: cloudKitSyncCoordinator,
                defaultWorkspaceName: defaultWorkspaceName,
                canonicalDefaultWorkspaceNames: canonicalDefaultWorkspaceNames,
                now: now,
                makeID: makeID
            )
        )
        let serverFormDependencies = ServerFormDependencies.live(
            credentials: keychainManager,
            hostKeys: knownHostsManager,
            connectionOperations: connectionOperations,
            remoteMosh: remoteMosh,
            defaultTmuxEnabled: {
                defaults.object(forKey: "terminalTmuxEnabledDefault") == nil
                    ? true
                    : defaults.bool(forKey: "terminalTmuxEnabledDefault")
            },
            defaultTmuxStartupBehavior: {
                defaults.string(forKey: "terminalTmuxStartupBehaviorDefault")
                    .flatMap(TmuxStartupBehavior.init(rawValue:)) ?? .askEveryTime
            },
            now: now,
            makeID: makeID
        )
        let engagementTracker = EngagementTracker(
            dependencies: .live(
                defaults: defaults,
                analytics: analyticsTracker,
                now: now,
                calendar: calendar,
                applicationIsActive: applicationIsActive
            )
        )
        let terminalThemeManager = TerminalThemeManager(
            dependencies: .live(
                defaults: defaults,
                notificationCenter: notificationCenter,
                cloud: cloudKitSync.terminalThemeCloud,
                mutationQueue: cloudKitSyncCoordinator,
                syncLifecycle: syncLifecycle,
                themeFiles: TerminalThemeFileStore.appStorage,
                builtInThemeCatalog: BundleTerminalThemeCatalog(),
                paletteResolver: ThemeColorParserPaletteResolver(),
                isSyncEnabled: isSyncEnabled,
                now: now
            )
        )
        let tabManager = TerminalTabManagerLiveComposition.makeManager(
            defaults: defaults,
            networkMonitor: networkMonitor,
            appLockManager: appLockManager,
            serverManager: serverManager,
            engagementTracker: engagementTracker,
            analyticsTracker: analyticsTracker,
            liveActivityManager: liveActivityManager,
            remoteMosh: remoteMosh,
            remoteTmux: remoteTmux,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshResumeStore: moshResumeStore,
            terminalSurfaceStore: terminalSurfaceStore,
            deviceID: deviceID,
            themeStyle: {
                TerminalTmuxSessionLiveComposition.themeStyle(
                    for: terminalThemeManager.themeSelection.darkThemeName
                )
            },
            applicationIsActive: applicationIsActive
        )
        let storeManager = StoreManager(
            client: AppStoreKitClient(),
            effects: .live(
                analytics: analyticsTracker,
                engagementTracker: engagementTracker
            )
        )
        let terminalAccessoryPreferencesManager = TerminalAccessoryPreferencesManager(
            dependencies: .live(
                defaults: defaults,
                cloud: cloudKitSync.terminalAccessoryCloud,
                mutationQueue: cloudKitSyncCoordinator,
                syncLifecycle: syncLifecycle,
                resolutionSource: cloudKitSync.terminalAccessoryResolutions,
                writerID: deviceID,
                isSyncEnabled: isSyncEnabled,
                now: now,
                makeID: makeID,
                trackCustomActionCreated: { kind in
                    analyticsTracker.trackCustomActionCreated(kind: kind.rawValue)
                }
            )
        )
        let statsPreferencesStore = PreferencesStore(
            dependencies: .live(
                defaults: defaults,
                cloud: cloudKitSync.statsPreferencesCloud,
                mutationQueue: cloudKitSyncCoordinator,
                syncLifecycle: syncLifecycle,
                resolutionSource: cloudKitSync.statsPreferencesResolutions,
                writerID: deviceID,
                isSyncEnabled: isSyncEnabled,
                now: now
            )
        )
        let serverVolumeVisibilityStore = ServerVolumeVisibilityStore.live
        #if os(macOS)
        let workspaceSelectionStore = WorkspaceSelectionLiveComposition.makeStore(
            defaults: defaults
        )
        #endif
        let viewTabConfigurationManager = ViewTabConfigurationManager(defaults: defaults)
        let voiceSettingsPersistence = UserDefaultsVoiceSettingsPersistence(defaults: defaults)
        let voiceSettingsStore = VoiceSettingsStore(persistence: voiceSettingsPersistence)
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
        let voiceInputRuntimeStore = VoiceInputRuntimeStore(
            settingsStore: voiceSettingsStore,
            makeRuntime: VoiceInputRuntimeLiveComposition.makeFactory(
                settingsStore: voiceSettingsStore
            )
        )
        let makeStatsCollector = Self.makeStatsCollectorFactory(
            keychainManager: keychainManager,
            connectionOperations: connectionOperations
        )
        terminalSecurityActions = Self.makeTerminalSecurityActions(
            keychainManager: keychainManager,
            knownHostsManager: knownHostsManager
        )
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
        #if os(iOS)
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
        #if os(macOS)
        _workspaceSelectionStore = StateObject(wrappedValue: workspaceSelectionStore)
        #endif
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        self.makeStatsCollector = makeStatsCollector
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.serverFormDependencies = serverFormDependencies
        self.voiceModelManagers = voiceModelManagers
        statsSecurityApprovalActions = Self.makeStatsSecurityApprovalActions(
            appLockManager: appLockManager,
            keychainManager: keychainManager,
            knownHostsManager: knownHostsManager
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
        aboutWindowPresenter = AboutWindowPresenter()
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
            voiceModelManagers: voiceModelManagers,
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
    #if os(macOS)
    @StateObject private var workspaceSelectionStore: WorkspaceSelectionStore
    #endif
    private let voiceInputRuntimeStore: VoiceInputRuntimeStore
    @StateObject private var viewTabConfigurationManager: ViewTabConfigurationManager
    @StateObject private var syncSettingsCoordinator: SyncSettingsCoordinator
    @StateObject private var sshKeySettingsCoordinator: SSHKeySettingsCoordinator
    @StateObject private var knownHostSettingsCoordinator: KnownHostSettingsCoordinator
    private let onWelcomeCompleted: @MainActor () -> Void
    private let makeStatsCollector: @MainActor () -> ServerStatsCollector
    private let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    private let serverFormDependencies: ServerFormDependencies
    private let voiceModelManagers: VoiceSettingsModelManagerOwner
    private let statsSecurityApprovalActions: ServerStatsSecurityApprovalActions
    private let terminalSecurityActions: TerminalSecurityActions
    #if os(macOS)
    private let aboutWindowPresenter: AboutWindowPresenter
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
            makeCollector: makeStatsCollector,
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
            terminalSecurityActions: terminalSecurityActions,
            serverFormDependencies: serverFormDependencies,
            workspaceSelectionStore: workspaceSelectionStore,
            voiceInputRuntimeStore: voiceInputRuntimeStore,
            makeLocalDiscoveryManager: makeLocalDiscoveryManager,
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
                statsDependencies: statsDependencies,
                terminalSecurityActions: terminalSecurityActions,
                serverFormDependencies: serverFormDependencies,
                voiceModelManagers: voiceModelManagers,
                voiceInputRuntimeStore: voiceInputRuntimeStore,
                makeLocalDiscoveryManager: makeLocalDiscoveryManager
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
            terminalSecurityActions: terminalSecurityActions,
            serverFormDependencies: serverFormDependencies,
            voiceModelManagers: voiceModelManagers,
            voiceInputRuntimeStore: voiceInputRuntimeStore,
            makeLocalDiscoveryManager: makeLocalDiscoveryManager,
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
            VVTermCommands(
                aboutWindowPresenter: aboutWindowPresenter,
                settingsWindowPresenter: settingsWindowPresenter
            )
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
    static func makeStatsCollectorFactory(
        keychainManager: KeychainManager,
        connectionOperations: SSHConnectionOperationService
    ) -> @MainActor () -> ServerStatsCollector {
        let dependencies = ServerStatsCollectorDependencies.live(
            keychainManager: keychainManager,
            connectionOperations: connectionOperations
        )
        return {
            ServerStatsCollector(dependencies: dependencies)
        }
    }

    static func makeTerminalSecurityActions(
        keychainManager: KeychainManager,
        knownHostsManager: KnownHostsManager
    ) -> TerminalSecurityActions {
        TerminalSecurityActions(
            loadCredentials: { server in
                try keychainManager.getCredentials(for: server)
            },
            pendingHostKeyApproval: { server in
                knownHostsManager.pendingChallenge(
                    for: server.host,
                    port: server.port
                ).map(TerminalSecurityApprovalRequest.hostKey)
            },
            approve: { request, server in
                switch request {
                case .credentialEndpoint(let serverID):
                    guard serverID == server.id else {
                        return .failed(.expired)
                    }
                    do {
                        try keychainManager.approveCredentialUse(for: server)
                        return .approved
                    } catch {
                        return .failed(.unavailable)
                    }
                case .hostKey(let challenge):
                    return knownHostsManager.approve(challenge)
                        ? .approved
                        : .failed(.expired)
                }
            },
            reject: { request in
                guard case .hostKey(let challenge) = request else { return }
                knownHostsManager.reject(challenge)
            }
        )
    }

    static func makeStatsSecurityApprovalActions(
        appLockManager: AppLockManager,
        keychainManager: KeychainManager,
        knownHostsManager: KnownHostsManager
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
                        try keychainManager.approveCredentialUse(for: server)
                        return .approved
                    } catch {
                        return .failed(.unavailable)
                    }
                case .hostKey(let challenge):
                    return knownHostsManager.approve(challenge)
                        ? .approved
                        : .failed(.expired)
                }
            },
            reject: { request in
                guard case .hostKey(let challenge) = request else { return }
                knownHostsManager.reject(challenge)
            }
        )
    }

    static func makeRemoteFileBrowserStore(
        tabManager: TerminalTabManager,
        serverManager: ServerManager,
        defaults: UserDefaults = .standard
    ) -> RemoteFileBrowserStore {
        let adapter = SSHSFTPAdapter(borrowedClientProvider: { serverId in
            tabManager.transportCoordinator.sharedStatsClient(for: serverId)
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
