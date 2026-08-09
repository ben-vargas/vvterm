import Foundation

@MainActor
private final class UserDefaultsTerminalThemePreferenceChangeSource: TerminalThemePreferenceChangeSource {
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func observeChanges(
        to defaults: UserDefaults,
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
        TerminalThemeManagerDependencies(
            defaults: .standard,
            cloud: CloudKitManager.shared,
            mutationQueue: CloudKitSyncCoordinator.shared,
            syncLifecycle: CloudKitSyncLifecycleDriver.shared,
            preferenceChanges: UserDefaultsTerminalThemePreferenceChangeSource(
                notificationCenter: .default
            ),
            fileStore: .appStorage,
            persistenceKeys: TerminalThemePersistenceKeys(
                customThemes: CloudKitSyncConstants.terminalCustomThemesStorageKey,
                darkTheme: CloudKitSyncConstants.terminalThemeNameKey,
                lightTheme: CloudKitSyncConstants.terminalThemeNameLightKey,
                usesPerAppearanceTheme: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey,
                preferenceUpdatedAt: CloudKitSyncConstants.terminalThemePreferenceUpdatedAtKey,
                activeBackgroundCache: "terminalBackgroundColor"
            ),
            isSyncEnabled: { SyncSettings.isEnabled },
            now: Date.init,
            waitForPreferenceSyncDebounce: {
                try await Task.sleep(nanoseconds: 600_000_000)
            },
            startsSynchronization: true
        )
    }
}

extension TerminalThemeManager {
    static let shared = TerminalThemeManager(dependencies: .live)
}
