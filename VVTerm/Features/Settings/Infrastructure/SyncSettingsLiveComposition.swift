import Combine
import Foundation

@MainActor
private final class CloudKitSyncSettingsAdapter: SyncSettingsCloudSyncing {
    private let cloudKit: CloudKitManager
    private let statusStore: CloudKitSyncStatusStore

    init(cloudKit: CloudKitManager) {
        self.cloudKit = cloudKit
        statusStore = cloudKit.statusStore
    }

    var currentState: SyncSettingsCloudState {
        Self.state(
            syncState: statusStore.syncState,
            lastSyncDate: statusStore.lastSyncDate,
            accountState: statusStore.accountState
        )
    }

    var stateUpdates: AnyPublisher<SyncSettingsCloudState, Never> {
        Publishers.CombineLatest3(
            statusStore.$syncState,
            statusStore.$lastSyncDate,
            statusStore.$accountState
        )
        .map { syncState, lastSyncDate, accountState in
            Self.state(
                syncState: syncState,
                lastSyncDate: lastSyncDate,
                accountState: accountState
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
        accountState: CloudKitAccountState
    ) -> SyncSettingsCloudState {
        SyncSettingsCloudState(
            status: status(syncState.status),
            isAvailable: syncState.isAvailable,
            lastSyncDate: lastSyncDate,
            accountState: accountState
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
