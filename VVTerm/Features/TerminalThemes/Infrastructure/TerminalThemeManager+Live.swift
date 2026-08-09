import Foundation

@MainActor
private final class UserDefaultsTerminalThemePreferenceChangeSource: TerminalThemePreferenceChangeSource {
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults,
        notificationCenter: NotificationCenter
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    func observeChanges(
        _ observer: @escaping () -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { _ in
            observer()
        }
    }

    func removeObserver(_ observer: NSObjectProtocol) {
        notificationCenter.removeObserver(observer)
    }
}

extension CloudKitManager: TerminalThemeCloudClient {}
extension CloudKitSyncCoordinator: TerminalThemeMutationQueue {}
extension CloudKitSyncLifecycleDriver: TerminalThemeSyncLifecycle {}

extension TerminalThemeManagerDependencies {
    static var live: Self {
        let defaults = UserDefaults.standard
        let keys = TerminalThemeUserDefaultsKeys(
            customThemes: CloudKitSyncConstants.terminalCustomThemesStorageKey,
            darkTheme: CloudKitSyncConstants.terminalThemeNameKey,
            lightTheme: CloudKitSyncConstants.terminalThemeNameLightKey,
            usesPerAppearanceTheme: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey,
            preferenceUpdatedAt: CloudKitSyncConstants.terminalThemePreferenceUpdatedAtKey,
            activeBackgroundCache: "terminalBackgroundColor"
        )
        return TerminalThemeManagerDependencies(
            persistence: UserDefaultsTerminalThemePersistence(
                defaults: defaults,
                keys: keys
            ),
            cloud: CloudKitManager.shared,
            mutationQueue: CloudKitSyncCoordinator.shared,
            syncLifecycle: CloudKitSyncLifecycleDriver.shared,
            preferenceChanges: UserDefaultsTerminalThemePreferenceChangeSource(
                defaults: defaults,
                notificationCenter: .default
            ),
            themeFiles: TerminalThemeFileStore.appStorage,
            builtInThemeCatalog: BundleTerminalThemeCatalog(),
            paletteResolver: ThemeColorParserPaletteResolver(),
            isSyncEnabled: { SyncSettings.isEnabled },
            now: Date.init,
            waitForPreferenceSyncDebounce: {
                try await Task.sleep(nanoseconds: 600_000_000)
            },
            startsSynchronization: true
        )
    }
}
