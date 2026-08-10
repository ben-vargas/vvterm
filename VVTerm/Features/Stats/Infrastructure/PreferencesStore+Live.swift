import Foundation

extension CloudKitSyncCoordinator: StatsPreferencesMutationQueue {}
extension CloudKitSyncLifecycleDriver: StatsPreferencesSyncLifecycle {}

@MainActor
enum StatsPreferencesCloudKitLiveComposition {
    static let client = StatsPreferencesCloudKitClient(
        transport: CloudKitManager.shared
    )
}

extension CloudKitSyncResolutionHub: StatsPreferencesResolutionSource {
    func observeStatsPreferences(
        _ observer: @escaping (StatsPreferences) -> Void
    ) -> UUID {
        observe { resolution in
            guard case .statsPreferences(let preferences) = resolution else { return }
            observer(preferences)
        }
    }

    func removeStatsPreferencesObserver(_ id: UUID) {
        removeObserver(id)
    }
}

extension PreferencesStoreDependencies {
    static func live(
        mutationQueue: any StatsPreferencesMutationQueue
    ) -> Self {
        PreferencesStoreDependencies(
            persistence: UserDefaultsStatsPreferencesStore(
                defaults: .standard,
                key: CloudKitSyncConstants.statsPreferencesStorageKey
            ),
            cloud: StatsPreferencesCloudKitLiveComposition.client,
            mutationQueue: mutationQueue,
            syncLifecycle: CloudKitSyncLifecycleDriver.shared,
            resolutionSource: CloudKitSyncResolutionHub.shared,
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
