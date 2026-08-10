import Foundation

extension CloudKitSyncCoordinator: StatsPreferencesMutationQueue {
    func enqueueStatsPreferencesUpsert(_ preferences: StatsPreferences) {
        enqueue(
            PendingCloudKitMutation(
                payload: .statsPreferencesUpsert(preferences)
            )
        )
    }
}
extension CloudKitSyncLifecycleDriver: StatsPreferencesSyncLifecycle {}

@MainActor
enum StatsPreferencesCloudKitLiveComposition {
    static let client = StatsPreferencesCloudKitClient(
        transport: CloudKitManager.shared
    )
}

extension PreferencesStoreDependencies {
    static func live(
        mutationQueue: any StatsPreferencesMutationQueue,
        resolutionSource: any StatsPreferencesResolutionSource
    ) -> Self {
        PreferencesStoreDependencies(
            persistence: UserDefaultsStatsPreferencesStore(
                defaults: .standard,
                key: CloudKitSyncConstants.statsPreferencesStorageKey
            ),
            cloud: StatsPreferencesCloudKitLiveComposition.client,
            mutationQueue: mutationQueue,
            syncLifecycle: CloudKitSyncLifecycleDriver.shared,
            resolutionSource: resolutionSource,
            writerID: DeviceIdentity.id,
            isSyncEnabled: { SyncSettings.isEnabled },
            now: Date.init,
            waitForSyncDebounce: {
                try await Task.sleep(nanoseconds: 650_000_000)
            },
            startsSynchronization: true
        )
    }
}
