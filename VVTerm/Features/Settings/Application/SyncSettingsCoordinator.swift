import Combine
import Foundation

nonisolated struct SyncSettingsCloudState: Equatable, Sendable {
    nonisolated enum Status: Equatable, Sendable {
        case idle
        case syncing
        case error(String)
        case offline
        case disabled
    }

    let status: Status
    let isAvailable: Bool
    let lastSyncDate: Date?
    let accountState: CloudKitAccountState
}

@MainActor
protocol SyncSettingsCloudSyncing: AnyObject {
    var currentState: SyncSettingsCloudState { get }
    var stateUpdates: AnyPublisher<SyncSettingsCloudState, Never> { get }

    func setSyncEnabled(_ enabled: Bool)
    func refreshAccountStatus() async
}

@MainActor
protocol SyncSettingsCredentialSyncing: AnyObject {
    func prepareCredentialStorage(isSyncEnabled: Bool) throws
    func removeCloudCredentials() throws
}

@MainActor
protocol SyncSettingsDataRefreshing: AnyObject {
    func handleSyncDisabled()
    func refreshAfterSyncEnabled() async
}

@MainActor
final class SyncSettingsCoordinator: ObservableObject {
    enum CredentialFailure: Equatable {
        case toggle
        case removal
    }

    @Published private(set) var cloudState: SyncSettingsCloudState
    @Published private(set) var credentialFailure: CredentialFailure?

    private let cloud: any SyncSettingsCloudSyncing
    private let credentials: any SyncSettingsCredentialSyncing
    private let data: any SyncSettingsDataRefreshing
    private var cloudStateObservation: AnyCancellable?

    init(
        cloud: any SyncSettingsCloudSyncing,
        credentials: any SyncSettingsCredentialSyncing,
        data: any SyncSettingsDataRefreshing
    ) {
        self.cloud = cloud
        self.credentials = credentials
        self.data = data
        cloudState = cloud.currentState
        cloudStateObservation = cloud.stateUpdates
            .removeDuplicates()
            .sink { [weak self] state in
                self?.cloudState = state
            }
    }

    @discardableResult
    func setSyncEnabled(_ enabled: Bool) -> Bool {
        do {
            try credentials.prepareCredentialStorage(isSyncEnabled: enabled)
        } catch {
            credentialFailure = .toggle
            return false
        }

        credentialFailure = nil
        if !enabled {
            data.handleSyncDisabled()
        }
        cloud.setSyncEnabled(enabled)
        return true
    }

    func refreshAfterSyncEnabled() async {
        await data.refreshAfterSyncEnabled()
    }

    func refreshAccountStatus() async {
        await cloud.refreshAccountStatus()
    }

    func removeCloudCredentials() {
        do {
            try credentials.removeCloudCredentials()
            credentialFailure = nil
        } catch {
            credentialFailure = .removal
        }
    }
}
