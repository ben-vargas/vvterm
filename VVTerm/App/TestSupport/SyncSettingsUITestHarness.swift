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
    private let recovery = CurrentValueSubject<Bool, Never>(
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-sync-settings-recovery")
    )
    var needsCloudRecovery: Bool { recovery.value }
    var cloudRecoveryUpdates: AnyPublisher<Bool, Never> { recovery.eraseToAnyPublisher() }
    func resolveCloudRecovery(_ choice: AmbiguousCloudRecoveryChoice) async throws {
        recovery.send(false)
    }
    func handleSyncDisabled() {}
    func syncNow() async throws {}
}

@MainActor
private final class SyncSettingsUITestContent: SyncSettingsContentSummarizing {
    let currentSummary = SyncSettingsContentSummary(
        workspaceCount: 2,
        serverCount: 7,
        customThemeCount: 3,
        customFontCount: 2,
        serverCredentialCount: 6,
        reusableSSHKeyCount: 4
    )
}

@MainActor
private final class SyncSettingsUITestHistory: SyncSettingsHistoryStoring {
    private(set) var lastSuccessfulSyncDate: Date? = Date()

    func recordSuccessfulSync(at date: Date) throws {
        lastSuccessfulSyncDate = date
    }
}

struct SyncSettingsUITestHarness: View {
    @StateObject private var coordinator: SyncSettingsCoordinator

    init() {
        let isEnabled = !Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-sync-settings-disabled"
        )
        _coordinator = StateObject(wrappedValue: Self.makeCoordinator(isEnabled: isEnabled))
    }

    private static func makeCoordinator(isEnabled: Bool) -> SyncSettingsCoordinator {
        // Run once for the StateObject, not on each SwiftUI view initialization.
        try? SyncSettings.persistEnabled(isEnabled)
        return SyncSettingsCoordinator(
            cloud: SyncSettingsUITestCloud(isEnabled: isEnabled),
            credentials: SyncSettingsUITestCredentials(isEnabled: isEnabled),
            data: SyncSettingsUITestData(),
            content: SyncSettingsUITestContent(),
            history: SyncSettingsUITestHistory(),
            runtime: SyncSettingsRuntimeInfo(
                appVersion: "UI Test",
                buildVersion: "1",
                platform: "UI Test"
            )
        )
    }

    var body: some View {
        NavigationStack {
            SyncSettingsView()
                .navigationTitle("iCloud Sync")
        }
        .environmentObject(coordinator)
        .accessibilityIdentifier("vvterm.syncSettingsTest.root")
    }
}
#endif
