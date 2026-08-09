import Foundation

extension CloudKitManager: StatsPreferencesCloudClient {}
extension CloudKitSyncCoordinator: StatsPreferencesMutationQueue {}
extension CloudKitSyncLifecycleDriver: StatsPreferencesSyncLifecycle {}

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
    static var live: Self {
        PreferencesStoreDependencies(
            persistence: UserDefaultsStatsPreferencesStore(
                defaults: .standard,
                key: CloudKitSyncConstants.statsPreferencesStorageKey
            ),
            cloud: CloudKitManager.shared,
            mutationQueue: CloudKitSyncCoordinator.shared,
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

extension PreferencesStore {
    static let shared = PreferencesStore(dependencies: .live)
}

extension ServerVolumeVisibilityStore {
    static let shared = ServerVolumeVisibilityStore(defaults: .standard)
}
