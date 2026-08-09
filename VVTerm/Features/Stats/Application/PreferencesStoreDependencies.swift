import Foundation

@MainActor
protocol StatsPreferencesCloudClient: AnyObject {
    func syncStatsPreferences(
        _ localPreferences: StatsPreferences
    ) async throws -> StatsPreferences
}

@MainActor
protocol StatsPreferencesMutationQueue: AnyObject {
    func enqueueStatsPreferencesUpsert(_ preferences: StatsPreferences)
    func drainPendingMutations() async
}

@MainActor
protocol StatsPreferencesSyncLifecycle: AnyObject {
    func observe(
        _ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void
    ) -> UUID
    func removeObserver(_ id: UUID)
}

@MainActor
protocol StatsPreferencesResolutionSource: AnyObject {
    func observeStatsPreferences(
        _ observer: @escaping (StatsPreferences) -> Void
    ) -> UUID
    func removeStatsPreferencesObserver(_ id: UUID)
}

@MainActor
struct PreferencesStoreDependencies {
    let defaults: UserDefaults
    let cloud: any StatsPreferencesCloudClient
    let mutationQueue: any StatsPreferencesMutationQueue
    let syncLifecycle: any StatsPreferencesSyncLifecycle
    let resolutionSource: any StatsPreferencesResolutionSource
    let persistenceKey: String
    let writerID: String
    let isSyncEnabled: () -> Bool
    let now: () -> Date
    let waitForSyncDebounce: () async throws -> Void
    let startsSynchronization: Bool
}
