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
        let tabManager = TerminalTabManagerLiveComposition.makeManager()
        let storeManager = StoreManager(
            client: AppStoreKitClient(),
            effects: .live
        )
        _tabManager = StateObject(wrappedValue: tabManager)
        _storeManager = StateObject(wrappedValue: storeManager)
        _remoteFileBrowserStore = StateObject(
            wrappedValue: Self.makeRemoteFileBrowserStore(tabManager: tabManager)
        )
        appDelegate.configure(tabManager: tabManager)
        #if os(macOS)
        MacConnectionToolbarController.shared.configure(tabManager: tabManager)
        #endif
        storeManager.start()

        TerminalDefaults.applyIfNeeded()
        #if os(iOS)
        VVTermLauncherWidgetRefresh.refreshIfNeeded()
        AnalyticsTracker.shared.prepareAppleAdsAttribution()
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
    #endif
    @StateObject private var appLockManager = AppLockManager.shared
    @StateObject private var tabManager: TerminalTabManager
    @StateObject private var storeManager: StoreManager
    @StateObject private var remoteFileTabManager = RemoteFileTabManager()
    @StateObject private var remoteFileBrowserStore: RemoteFileBrowserStore
    @StateObject private var terminalThemeManager = TerminalThemeManager.shared
    @StateObject private var terminalAccessoryPreferencesManager = TerminalAccessoryPreferencesManager.shared

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
            tabManager: tabManager,
            fileTabs: remoteFileTabManager,
            fileBrowser: remoteFileBrowserStore
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
                WelcomeView(hasSeenWelcome: $hasSeenWelcome)
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
            TerminalReconnectUITestHarness(tabManager: tabManager)
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
            tabManager: tabManager,
            fileTabs: remoteFileTabManager,
            fileBrowser: remoteFileBrowserStore
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
                WelcomeView(hasSeenWelcome: $hasSeenWelcome)
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
                        ServerManager.shared.handleAppLanguageChange()
                    }
                    .onChange(of: appLanguage) { newValue in
                        AppLanguage.applySelection(newValue)
                        ServerManager.shared.handleAppLanguageChange()
                    }
                }
            }
            .environmentObject(appLockManager)
            .environmentObject(storeManager)
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            VVTermCommands(storeManager: storeManager)
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
    static func makeRemoteFileBrowserStore(
        tabManager: TerminalTabManager,
        defaults: UserDefaults = .standard
    ) -> RemoteFileBrowserStore {
        let adapter = SSHSFTPAdapter(borrowedClientProvider: { serverId in
            tabManager.sharedStatsClient(for: serverId)
        })

        return RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: adapter,
            serverProvider: { serverId in
                ServerManager.shared.servers.first { $0.id == serverId }
            },
            workingDirectoryProvider: { serverId in
                tabManager.workingDirectoryCandidate(for: serverId)
            }
        )
    }
}
