import Foundation

extension CloudKitSyncCoordinator: TerminalAccessoryMutationQueue {}
extension CloudKitSyncLifecycleDriver: TerminalAccessorySyncLifecycle {}

@MainActor
enum TerminalAccessoryCloudKitLiveComposition {
    static let client = TerminalAccessoryCloudKitClient(
        transport: CloudKitManager.shared
    )
}

extension CloudKitSyncResolutionHub: TerminalAccessoryResolutionSource {
    func observeTerminalAccessoryProfile(
        _ observer: @escaping (TerminalAccessoryProfile) -> Void
    ) -> UUID {
        observe { resolution in
            guard case .terminalAccessoryProfile(let profile) = resolution else { return }
            observer(profile)
        }
    }

    func removeTerminalAccessoryProfileObserver(_ id: UUID) {
        removeObserver(id)
    }
}

extension TerminalAccessoryPreferencesDependencies {
    static var live: Self {
        TerminalAccessoryPreferencesDependencies(
            profileStore: UserDefaultsTerminalAccessoryProfileStore(
                defaults: .standard,
                key: CloudKitSyncConstants.terminalAccessoryProfileStorageKey
            ),
            cloud: TerminalAccessoryCloudKitLiveComposition.client,
            mutationQueue: CloudKitSyncCoordinator.shared,
            syncLifecycle: CloudKitSyncLifecycleDriver.shared,
            resolutionSource: CloudKitSyncResolutionHub.shared,
            writerID: DeviceIdentity.id,
            isSyncEnabled: { SyncSettings.isEnabled },
            now: Date.init,
            makeID: UUID.init,
            trackCustomActionCreated: { kind in
                AnalyticsTracker.shared.trackCustomActionCreated(kind: kind.rawValue)
            },
            waitForSyncDebounce: {
                try await Task.sleep(nanoseconds: 650_000_000)
            },
            startsSynchronization: true
        )
    }
}
