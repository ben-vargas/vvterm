import Foundation

@MainActor
struct CloudKitSyncClients {
    let serverCloud: any ServerRemoteMutationClient
    let terminalThemeCloud: any TerminalThemeCloudMutationClient
    let terminalAccessoryCloud: any TerminalAccessoryCloudClient
    let statsPreferencesCloud: any StatsPreferencesCloudClient
}

@MainActor
enum CloudKitSyncLiveComposition {
    static func makeCoordinator(
        clients: CloudKitSyncClients,
        queue: PendingCloudKitSyncQueue,
        resolutionHub: CloudKitSyncResolutionHub,
        isSyncEnabled: @escaping () -> Bool,
        now: @escaping () -> Date
    ) -> CloudKitSyncCoordinator {
        CloudKitSyncCoordinator(
            serverCloud: clients.serverCloud,
            terminalThemeCloud: clients.terminalThemeCloud,
            terminalAccessoryCloud: clients.terminalAccessoryCloud,
            statsPreferencesCloud: clients.statsPreferencesCloud,
            queue: queue,
            resolutionHub: resolutionHub,
            isSyncEnabled: isSyncEnabled,
            now: now
        )
    }

    static func makeLiveCoordinator() -> CloudKitSyncCoordinator {
        makeCoordinator(
            clients: CloudKitSyncClients(
                serverCloud: ServerCloudKitLiveComposition.client,
                terminalThemeCloud: TerminalThemeCloudKitLiveComposition.client,
                terminalAccessoryCloud: TerminalAccessoryCloudKitLiveComposition.client,
                statsPreferencesCloud: StatsPreferencesCloudKitLiveComposition.client
            ),
            queue: PendingCloudKitSyncQueue(),
            resolutionHub: CloudKitSyncResolutionHub.shared,
            isSyncEnabled: { SyncSettings.isEnabled },
            now: Date.init
        )
    }
}

extension ServerManager {
    /// Compatibility composition for the Remote Files default initializer.
    /// App roots must construct and inject their own manager instead.
    static let shared: ServerManager = {
        let syncCoordinator = CloudKitSyncLiveComposition.makeLiveCoordinator()
        return ServerManager(
            dependencies: .live(
                actionAuthorizer: AppLockManager.shared,
                syncRepository: syncCoordinator
            )
        )
    }()
}
