import Foundation

@MainActor
protocol TerminalAccessoryCloudClient: AnyObject {
    func syncTerminalAccessoryProfile(
        _ localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile
}

@MainActor
protocol TerminalAccessoryMutationQueue: AnyObject {
    func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile)
    func drainPendingMutations() async
}

@MainActor
protocol TerminalAccessorySyncLifecycle: AnyObject {
    func observe(
        _ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void
    ) -> UUID
    func removeObserver(_ id: UUID)
}

@MainActor
protocol TerminalAccessoryResolutionSource: AnyObject {
    func observeTerminalAccessoryProfile(
        _ observer: @escaping (TerminalAccessoryProfile) -> Void
    ) -> UUID
    func removeTerminalAccessoryProfileObserver(_ id: UUID)
}

@MainActor
struct TerminalAccessoryPreferencesDependencies {
    let defaults: UserDefaults
    let cloud: any TerminalAccessoryCloudClient
    let mutationQueue: any TerminalAccessoryMutationQueue
    let syncLifecycle: any TerminalAccessorySyncLifecycle
    let resolutionSource: any TerminalAccessoryResolutionSource
    let persistenceKey: String
    let writerID: String
    let isSyncEnabled: () -> Bool
    let now: () -> Date
    let makeID: () -> UUID
    let trackCustomActionCreated: (TerminalAccessoryCustomActionKind) -> Void
    let publishProfileChange: (AnyObject, TerminalAccessoryProfile) -> Void
    let waitForSyncDebounce: () async throws -> Void
    let startsSynchronization: Bool
}
