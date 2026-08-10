import Combine
import Foundation

@MainActor
private final class CloudKitSyncSettingsAdapter: SyncSettingsCloudSyncing {
    private let cloudKit: CloudKitManager

    init(cloudKit: CloudKitManager) {
        self.cloudKit = cloudKit
    }

    var currentState: SyncSettingsCloudState {
        Self.state(
            syncState: cloudKit.syncState,
            lastSyncDate: cloudKit.lastSyncDate,
            accountStatusDetail: cloudKit.accountStatusDetail
        )
    }

    var stateUpdates: AnyPublisher<SyncSettingsCloudState, Never> {
        Publishers.CombineLatest3(
            cloudKit.$syncState,
            cloudKit.$lastSyncDate,
            cloudKit.$accountStatusDetail
        )
        .map { syncState, lastSyncDate, accountStatusDetail in
            Self.state(
                syncState: syncState,
                lastSyncDate: lastSyncDate,
                accountStatusDetail: accountStatusDetail
            )
        }
        .eraseToAnyPublisher()
    }

    func setSyncEnabled(_ enabled: Bool) {
        cloudKit.handleSyncToggle(enabled)
    }

    func refreshAccountStatus() async {
        await cloudKit.forceSync()
    }

    private static func state(
        syncState: CloudKitSyncState,
        lastSyncDate: Date?,
        accountStatusDetail: String
    ) -> SyncSettingsCloudState {
        SyncSettingsCloudState(
            status: status(syncState.status),
            isAvailable: syncState.isAvailable,
            lastSyncDate: lastSyncDate,
            accountStatusDetail: accountStatusDetail
        )
    }

    private static func status(
        _ status: CloudKitSyncState.Status
    ) -> SyncSettingsCloudState.Status {
        switch status {
        case .idle:
            return .idle
        case .syncing:
            return .syncing
        case .error(let message):
            return .error(message)
        case .offline:
            return .offline
        case .disabled:
            return .disabled
        }
    }
}

@MainActor
private final class KeychainSyncSettingsAdapter: SyncSettingsCredentialSyncing {
    private let keychain: KeychainManager

    init(keychain: KeychainManager) {
        self.keychain = keychain
    }

    func prepareCredentialStorage(isSyncEnabled: Bool) throws {
        try keychain.handleSyncToggle(isEnabled: isSyncEnabled)
    }

    func removeCloudCredentials() throws {
        try keychain.removeCredentialsFromICloud()
    }
}

@MainActor
private final class AppSyncSettingsDataAdapter: SyncSettingsDataRefreshing {
    private let serverManager: ServerManager
    private let terminalAccessory: TerminalAccessoryPreferencesManager

    init(
        serverManager: ServerManager,
        terminalAccessory: TerminalAccessoryPreferencesManager
    ) {
        self.serverManager = serverManager
        self.terminalAccessory = terminalAccessory
    }

    func handleSyncDisabled() {
        serverManager.handleSyncDisabled()
    }

    func refreshAfterSyncEnabled() async {
        await serverManager.loadData()
        await terminalAccessory.refreshFromCloud()
    }
}

@MainActor
enum SyncSettingsLiveComposition {
    static func makeCoordinator(
        cloudKit: CloudKitManager,
        keychain: KeychainManager,
        serverManager: ServerManager,
        terminalAccessory: TerminalAccessoryPreferencesManager
    ) -> SyncSettingsCoordinator {
        SyncSettingsCoordinator(
            cloud: CloudKitSyncSettingsAdapter(cloudKit: cloudKit),
            credentials: KeychainSyncSettingsAdapter(keychain: keychain),
            data: AppSyncSettingsDataAdapter(
                serverManager: serverManager,
                terminalAccessory: terminalAccessory
            )
        )
    }
}
