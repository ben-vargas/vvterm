import Foundation

@MainActor
struct CloudKitSyncClients {
    let serverCloud: any ServerRemoteMutationClient
    let terminalThemeCloud: any TerminalThemeCloudMutationClient
    let terminalAccessoryCloud: any TerminalAccessoryCloudClient
    let statsPreferencesCloud: any StatsPreferencesCloudClient
}

@MainActor
struct CloudKitSyncComposition {
    let coordinator: CloudKitSyncCoordinator
    let terminalAccessoryResolutions: TerminalAccessoryResolutionChannel
    let statsPreferencesResolutions: StatsPreferencesResolutionChannel
}

@MainActor
enum CloudKitSyncLiveComposition {
    static func make(
        clients: CloudKitSyncClients,
        queue: PendingCloudKitSyncQueue,
        isSyncEnabled: @escaping () -> Bool,
        now: @escaping () -> Date
    ) -> CloudKitSyncComposition {
        let terminalAccessoryResolutions = TerminalAccessoryResolutionChannel()
        let statsPreferencesResolutions = StatsPreferencesResolutionChannel()
        let mutationHandler = CloudKitPendingMutationRouter(
            serverCloud: clients.serverCloud,
            terminalThemeCloud: clients.terminalThemeCloud,
            terminalAccessoryHandler: TerminalAccessoryPendingMutationHandler(
                cloud: clients.terminalAccessoryCloud,
                resolutionPublisher: terminalAccessoryResolutions
            ),
            statsPreferencesHandler: StatsPreferencesPendingMutationHandler(
                cloud: clients.statsPreferencesCloud,
                resolutionPublisher: statsPreferencesResolutions
            )
        )
        return CloudKitSyncComposition(
            coordinator: CloudKitSyncCoordinator(
                mutationHandler: mutationHandler,
                queue: queue,
                isSyncEnabled: isSyncEnabled,
                now: now
            ),
            terminalAccessoryResolutions: terminalAccessoryResolutions,
            statsPreferencesResolutions: statsPreferencesResolutions
        )
    }

    static func makeLive() -> CloudKitSyncComposition {
        make(
            clients: CloudKitSyncClients(
                serverCloud: ServerCloudKitLiveComposition.client,
                terminalThemeCloud: TerminalThemeCloudKitLiveComposition.client,
                terminalAccessoryCloud: TerminalAccessoryCloudKitLiveComposition.client,
                statsPreferencesCloud: StatsPreferencesCloudKitLiveComposition.client
            ),
            queue: PendingCloudKitSyncQueue(),
            isSyncEnabled: { SyncSettings.isEnabled },
            now: Date.init
        )
    }
}

extension ServerManager {
    /// Compatibility composition for the Remote Files default initializer.
    /// App roots must construct and inject their own manager instead.
    static let shared: ServerManager = {
        let syncCoordinator = CloudKitSyncLiveComposition.makeLive().coordinator
        return ServerManager(
            dependencies: .live(
                actionAuthorizer: AppLockManager.shared,
                syncRepository: syncCoordinator
            )
        )
    }()
}
