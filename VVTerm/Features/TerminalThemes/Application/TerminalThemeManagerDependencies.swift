import Foundation

@MainActor
protocol TerminalThemeCloudClient: AnyObject {
    func fetchTerminalThemes() async throws -> [TerminalTheme]
    func fetchTerminalThemePreference() async throws -> TerminalThemePreference?
}

@MainActor
protocol TerminalThemeMutationQueue: AnyObject {
    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme)
    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference)
    func drainPendingMutations() async
}

@MainActor
protocol TerminalThemeSyncLifecycle: AnyObject {
    func observe(
        _ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void
    ) -> UUID
    func removeObserver(_ id: UUID)
}

@MainActor
protocol TerminalThemePreferenceChangeSource: AnyObject {
    func observeChanges(
        to defaults: UserDefaults,
        _ observer: @escaping () -> Void
    ) -> NSObjectProtocol
    func removeObserver(_ observer: NSObjectProtocol)
}

nonisolated struct TerminalThemePersistenceKeys: Equatable, Sendable {
    let customThemes: String
    let darkTheme: String
    let lightTheme: String
    let usesPerAppearanceTheme: String
    let preferenceUpdatedAt: String
    let activeBackgroundCache: String
}

@MainActor
struct TerminalThemeManagerDependencies {
    let defaults: UserDefaults
    let cloud: any TerminalThemeCloudClient
    let mutationQueue: any TerminalThemeMutationQueue
    let syncLifecycle: any TerminalThemeSyncLifecycle
    let preferenceChanges: any TerminalThemePreferenceChangeSource
    let fileStore: TerminalThemeFileStore
    let persistenceKeys: TerminalThemePersistenceKeys
    let isSyncEnabled: () -> Bool
    let now: () -> Date
    let waitForPreferenceSyncDebounce: () async throws -> Void
    let startsSynchronization: Bool
}
