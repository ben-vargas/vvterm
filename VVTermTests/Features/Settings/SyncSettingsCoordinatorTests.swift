import Combine
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class SyncSettingsActionLog {
    var events: [String] = []
}

@MainActor
private final class SyncSettingsCloudSpy: SyncSettingsCloudSyncing {
    let states: CurrentValueSubject<SyncSettingsCloudState, Never>
    let actionLog: SyncSettingsActionLog
    var toggles: [Bool] = []
    var refreshCount = 0

    init(
        state: SyncSettingsCloudState = .testValue,
        actionLog: SyncSettingsActionLog? = nil
    ) {
        states = CurrentValueSubject(state)
        self.actionLog = actionLog ?? SyncSettingsActionLog()
    }

    var currentState: SyncSettingsCloudState { states.value }
    var stateUpdates: AnyPublisher<SyncSettingsCloudState, Never> {
        states.eraseToAnyPublisher()
    }

    func setSyncEnabled(_ enabled: Bool) {
        toggles.append(enabled)
        actionLog.events.append("cloud:\(enabled)")
    }

    func refreshAccountStatus() async {
        refreshCount += 1
    }
}

@MainActor
private final class SyncSettingsCredentialSpy: SyncSettingsCredentialSyncing {
    let actionLog: SyncSettingsActionLog
    var preparedValues: [Bool] = []
    var prepareError: Error?

    init(actionLog: SyncSettingsActionLog? = nil) {
        self.actionLog = actionLog ?? SyncSettingsActionLog()
    }

    func prepareCredentialStorage(isSyncEnabled: Bool) throws {
        preparedValues.append(isSyncEnabled)
        actionLog.events.append("credentials:\(isSyncEnabled)")
        if let prepareError { throw prepareError }
    }

}

@MainActor
private final class SyncSettingsDataSpy: SyncSettingsDataRefreshing {
    let actionLog: SyncSettingsActionLog
    var disabledCount = 0
    var refreshCount = 0

    init(actionLog: SyncSettingsActionLog? = nil) {
        self.actionLog = actionLog ?? SyncSettingsActionLog()
    }

    func handleSyncDisabled() {
        disabledCount += 1
        actionLog.events.append("data-disabled")
    }

    func refreshAfterSyncEnabled() async {
        refreshCount += 1
        actionLog.events.append("data-refreshed")
    }
}

@MainActor
struct SyncSettingsCoordinatorTests {
    private enum TestError: Error {
        case failed
    }

    @Test
    func publishesCloudStateAndRoutesRefresh() async {
        let cloud = SyncSettingsCloudSpy()
        let coordinator = makeCoordinator(cloud: cloud)
        let updatedState = SyncSettingsCloudState(
            status: .offline,
            isAvailable: false,
            lastSyncDate: Date(timeIntervalSince1970: 42),
            accountState: .temporarilyUnavailable
        )

        cloud.states.send(updatedState)
        await coordinator.refreshAccountStatus()

        #expect(coordinator.cloudState == updatedState)
        #expect(cloud.refreshCount == 1)
    }

    @Test
    func enablingSyncPreparesCredentialsBeforeRefreshingData() async {
        let actionLog = SyncSettingsActionLog()
        let cloud = SyncSettingsCloudSpy(actionLog: actionLog)
        let credentials = SyncSettingsCredentialSpy(actionLog: actionLog)
        let data = SyncSettingsDataSpy(actionLog: actionLog)
        let coordinator = makeCoordinator(
            cloud: cloud,
            credentials: credentials,
            data: data
        )

        #expect(coordinator.setSyncEnabled(true))
        #expect(credentials.preparedValues == [true])
        #expect(cloud.toggles == [true])
        #expect(data.disabledCount == 0)
        #expect(data.refreshCount == 0)
        #expect(actionLog.events == ["credentials:true", "cloud:true"])

        await coordinator.refreshAfterSyncEnabled()
        #expect(data.refreshCount == 1)
        #expect(actionLog.events == ["credentials:true", "cloud:true", "data-refreshed"])
    }

    @Test
    func disablingSyncClearsErrorsAndStopsLocalSyncBeforeCloudToggle() {
        let actionLog = SyncSettingsActionLog()
        let cloud = SyncSettingsCloudSpy(actionLog: actionLog)
        let credentials = SyncSettingsCredentialSpy(actionLog: actionLog)
        let data = SyncSettingsDataSpy(actionLog: actionLog)
        credentials.prepareError = TestError.failed
        let coordinator = makeCoordinator(
            cloud: cloud,
            credentials: credentials,
            data: data
        )

        #expect(!coordinator.setSyncEnabled(true))
        #expect(coordinator.credentialFailure == .toggle)
        #expect(cloud.toggles.isEmpty)
        #expect(data.disabledCount == 0)
        #expect(actionLog.events == ["credentials:true"])

        credentials.prepareError = nil
        actionLog.events.removeAll()
        #expect(coordinator.setSyncEnabled(false))
        #expect(coordinator.credentialFailure == nil)
        #expect(credentials.preparedValues == [true, false])
        #expect(data.disabledCount == 1)
        #expect(cloud.toggles == [false])
        #expect(actionLog.events == ["credentials:false", "data-disabled", "cloud:false"])
    }

    @Test
    func accountStatusPresentationMapsEverySemanticStateToExactCopy() {
        let mappings: [(CloudKitAccountState, String)] = [
            (.checking, "Checking..."),
            (.available, "available"),
            (.noAccount, "noAccount - User not signed into iCloud"),
            (
                .restricted,
                "restricted - iCloud access restricted (parental controls, MDM, etc.)"
            ),
            (
                .couldNotDetermine,
                "couldNotDetermine - Unable to determine iCloud status"
            ),
            (
                .temporarilyUnavailable,
                "temporarilyUnavailable - iCloud temporarily unavailable"
            ),
            (.unknown(rawValue: 17), "unknown status: 17"),
            (.failed(detail: "Account lookup failed"), "Error: Account lookup failed"),
            (.disabled, "Disabled")
        ]

        for (state, expected) in mappings {
            #expect(SyncSettingsAccountStatusText.text(for: state) == expected)
        }
    }

    private func makeCoordinator(
        cloud: SyncSettingsCloudSpy? = nil,
        credentials: SyncSettingsCredentialSpy? = nil,
        data: SyncSettingsDataSpy? = nil
    ) -> SyncSettingsCoordinator {
        SyncSettingsCoordinator(
            cloud: cloud ?? SyncSettingsCloudSpy(),
            credentials: credentials ?? SyncSettingsCredentialSpy(),
            data: data ?? SyncSettingsDataSpy()
        )
    }
}

private extension SyncSettingsCloudState {
    static let testValue = SyncSettingsCloudState(
        status: .idle,
        isAvailable: true,
        lastSyncDate: nil,
        accountState: .available
    )
}
