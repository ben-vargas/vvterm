import Foundation

extension CloudKitSyncCoordinator: TerminalAccessoryMutationQueue {}
extension CloudKitSyncLifecycleDriver: TerminalAccessorySyncLifecycle {}

@MainActor
enum TerminalAccessoryCloudKitLiveComposition {
    static let client = TerminalAccessoryCloudKitClient(
        transport: CloudKitManager.shared
    )
}

extension TerminalAccessoryPreferencesDependencies {
    static func live(
        mutationQueue: any TerminalAccessoryMutationQueue,
        resolutionSource: any TerminalAccessoryResolutionSource
    ) -> Self {
        TerminalAccessoryPreferencesDependencies(
            profileStore: UserDefaultsTerminalAccessoryProfileStore(
                defaults: .standard,
                key: CloudKitSyncConstants.terminalAccessoryProfileStorageKey
            ),
            cloud: TerminalAccessoryCloudKitLiveComposition.client,
            mutationQueue: mutationQueue,
            syncLifecycle: CloudKitSyncLifecycleDriver.shared,
            resolutionSource: resolutionSource,
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
