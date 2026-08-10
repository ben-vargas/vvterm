import Foundation

extension CloudKitSyncCoordinator: StatsPreferencesMutationQueue {}
extension CloudKitSyncLifecycleDriver: StatsPreferencesSyncLifecycle {}

@MainActor
enum StatsPreferencesCloudKitLiveComposition {
    static let client = StatsPreferencesCloudKitClient(
        transport: CloudKitManager.shared
    )
}

extension CloudKitSyncCoordinator {
    static let shared = CloudKitSyncCoordinator(
        cloudKit: CloudKitManager.shared,
        terminalAccessoryCloud: TerminalAccessoryCloudKitLiveComposition.client,
        statsPreferencesCloud: StatsPreferencesCloudKitLiveComposition.client,
        queue: PendingCloudKitSyncQueue(),
        resolutionHub: CloudKitSyncResolutionHub.shared,
        isSyncEnabled: { SyncSettings.isEnabled },
        now: Date.init
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
    static var live: Self {
        PreferencesStoreDependencies(
            persistence: UserDefaultsStatsPreferencesStore(
                defaults: .standard,
                key: CloudKitSyncConstants.statsPreferencesStorageKey
            ),
            cloud: StatsPreferencesCloudKitLiveComposition.client,
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
