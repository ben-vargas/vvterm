#if DEBUG
import Combine
import SwiftUI

@MainActor
private final class SyncSettingsUITestCloud: SyncSettingsCloudSyncing {
    private let states: CurrentValueSubject<SyncSettingsCloudState, Never>

    init(isEnabled: Bool) {
        states = CurrentValueSubject(
            SyncSettingsCloudState(
                status: isEnabled ? .idle : .disabled,
                isAvailable: isEnabled,
                accountState: isEnabled ? .available : .disabled,
                pendingOperationCount: 0,
                hasPendingFailure: false,
                lastSuccessfulSyncDate: nil
            )
        )
    }

    var currentState: SyncSettingsCloudState { states.value }
    var stateUpdates: AnyPublisher<SyncSettingsCloudState, Never> {
        states.eraseToAnyPublisher()
    }

    func setSyncEnabled(_ enabled: Bool) {
        states.send(
            SyncSettingsCloudState(
                status: enabled ? .idle : .disabled,
                isAvailable: enabled,
                accountState: enabled ? .available : .disabled,
                pendingOperationCount: 0,
                hasPendingFailure: false,
                lastSuccessfulSyncDate: nil
            )
        )
    }

    func checkAccountStatus() async {}
}

@MainActor
private final class SyncSettingsUITestCredentials: SyncSettingsCredentialSyncing {
    private(set) var currentState: SyncSettingsCredentialState

    init(isEnabled: Bool) {
        currentState = isEnabled ? .storedInICloudKeychain : .storedOnThisDevice
    }

    func prepareCredentialStorage(isSyncEnabled: Bool) throws {
        currentState = isSyncEnabled ? .storedInICloudKeychain : .storedOnThisDevice
    }

    func removeCredentialsFromICloud() throws {
        currentState = .storedOnThisDevice
    }
}

@MainActor
private final class SyncSettingsUITestData: SyncSettingsDataRefreshing {
    func handleSyncDisabled() {}
    func syncNow() async throws {}
}

@MainActor
private final class SyncSettingsUITestHistory: SyncSettingsHistoryStoring {
    private(set) var lastSuccessfulSyncDate: Date?

    func recordSuccessfulSync(at date: Date) throws {
        lastSuccessfulSyncDate = date
    }
}

struct SyncSettingsUITestHarness: View {
    @StateObject private var coordinator: SyncSettingsCoordinator

    let serverManager: ServerManager
    let terminalAccessory: TerminalAccessoryPreferencesManager

    init(
        serverManager: ServerManager,
        terminalAccessory: TerminalAccessoryPreferencesManager
    ) {
        self.serverManager = serverManager
        self.terminalAccessory = terminalAccessory
        let isEnabled = !Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-sync-settings-disabled"
        )
        try? SyncSettings.persistEnabled(isEnabled)
        _coordinator = StateObject(
            wrappedValue: SyncSettingsCoordinator(
                cloud: SyncSettingsUITestCloud(isEnabled: isEnabled),
                credentials: SyncSettingsUITestCredentials(isEnabled: isEnabled),
                data: SyncSettingsUITestData(),
                history: SyncSettingsUITestHistory(),
                runtime: SyncSettingsRuntimeInfo(
                    appVersion: "UI Test",
                    buildVersion: "1",
                    platform: "UI Test"
                )
            )
        )
    }

    var body: some View {
        NavigationStack {
            SyncSettingsView()
                .navigationTitle("iCloud Sync")
        }
        .environmentObject(coordinator)
        .environmentObject(serverManager)
        .environmentObject(terminalAccessory)
        .accessibilityIdentifier("vvterm.syncSettingsTest.root")
    }
}
#endif
