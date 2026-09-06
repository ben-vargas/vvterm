import CloudKit
import Foundation
import Testing
@testable import VVTerm

private actor CloudKitAccountStatusGate {
    private var continuations: [CheckedContinuation<CKAccountStatus, Never>] = []

    func next() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForPendingRequest() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if !continuations.isEmpty { return true }
            await Task.yield()
        }
        return !continuations.isEmpty
    }

    func resumeNext(with status: CKAccountStatus) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: status)
    }
}

private actor CloudKitOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if continuation != nil { return true }
            await Task.yield()
        }
        return continuation != nil
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CloudKitSyncEnabledState {
    var value = true
}

@Suite(.serialized)
@MainActor
struct CloudKitManagerLifecycleTests {
    @Test
    func nestedPartialFailureContainingUnknownItemIsRecognized() {
        let zoneID = CKRecordZone.ID(zoneName: CloudKitSyncConstants.recordZoneName)
        let error = CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    zoneID: CKError(
                        .partialFailure,
                        userInfo: [
                            CKPartialErrorsByItemIDKey: [
                                CKRecord.ID(recordName: "missing-record"): CKError(.unknownItem)
                            ]
                        ]
                    )
                ]
            ]
        )

        #expect(CloudKitErrorClassifier.isMissingItem(error))
    }

    @Test(arguments: [CKError.Code.zoneNotFound, .userDeletedZone])
    func staleReadyZoneRecoversAndRetriesAfterTopLevelMissingZone(code: CKError.Code) async throws {
        var fetchCount = 0
        var saveCount = 0
        let manager = makeManager(
            zoneClient: CloudKitZoneClient(
                fetchZone: { _ in
                    fetchCount += 1
                    return nil
                },
                saveZone: { _ in saveCount += 1 }
            ),
            initialZoneReady: true
        )
        var operationCount = 0

        let value = try await manager.withZoneRetry {
            operationCount += 1
            if operationCount == 1 {
                throw CKError(code)
            }
            return 42
        }

        #expect(value == 42)
        #expect(operationCount == 2)
        #expect(fetchCount == 1)
        #expect(saveCount == 1)
        #expect(manager.zoneReady)
    }

    @Test(arguments: [CKError.Code.zoneNotFound, .userDeletedZone])
    func partialMissingZoneRecoversAndRetries(code: CKError.Code) async throws {
        var saveCount = 0
        let manager = makeManager(
            zoneClient: CloudKitZoneClient(
                fetchZone: { _ in nil },
                saveZone: { _ in saveCount += 1 }
            ),
            initialZoneReady: true
        )
        var operationCount = 0

        _ = try await manager.withZoneRetry {
            operationCount += 1
            if operationCount == 1 {
                throw self.partialMissingZoneError(for: manager.recordZoneID, code: code)
            }
            return true
        }

        #expect(operationCount == 2)
        #expect(saveCount == 1)
        #expect(manager.zoneReady)
    }

    @Test(arguments: [CKError.Code.zoneNotFound, .userDeletedZone])
    func zoneLookupPartialFailureRecreatesZone(code: CKError.Code) async throws {
        var fetchCount = 0
        var saveCount = 0
        let zoneID = CKRecordZone.ID(zoneName: CloudKitSyncConstants.recordZoneName)
        let manager = makeManager(
            zoneClient: CloudKitZoneClient(
                fetchZone: { _ in
                    fetchCount += 1
                    throw self.partialMissingZoneError(for: zoneID, code: code)
                },
                saveZone: { _ in saveCount += 1 }
            ),
            initialZoneReady: false
        )

        try await manager.ensureCustomZone()

        #expect(fetchCount == 1)
        #expect(saveCount == 1)
        #expect(manager.zoneReady)
    }

    @Test
    func failedZoneRecreationIsSurfacedWithoutRetryLoop() async {
        var saveCount = 0
        let manager = makeManager(
            zoneClient: CloudKitZoneClient(
                fetchZone: { _ in nil },
                saveZone: { _ in
                    saveCount += 1
                    throw CKError(.networkFailure)
                }
            ),
            initialZoneReady: true
        )
        var operationCount = 0

        do {
            let _: Bool = try await manager.withZoneRetry {
                operationCount += 1
                throw CKError(.zoneNotFound)
            }
            Issue.record("Expected zone recreation to fail")
        } catch let error as CKError {
            #expect(error.code == .networkFailure)
        } catch {
            Issue.record("Expected a CloudKit error")
        }

        #expect(operationCount == 1)
        #expect(saveCount == 1)
        #expect(!manager.zoneReady)
    }

    @Test
    func missingZoneRetryStopsAfterOneAttempt() async {
        var saveCount = 0
        let manager = makeManager(
            zoneClient: CloudKitZoneClient(
                fetchZone: { _ in nil },
                saveZone: { _ in saveCount += 1 }
            ),
            initialZoneReady: true
        )
        var operationCount = 0

        do {
            let _: Bool = try await manager.withZoneRetry {
                operationCount += 1
                throw CKError(.zoneNotFound)
            }
            Issue.record("Expected the retry to fail")
        } catch let error as CKError {
            #expect(error.code == .zoneNotFound)
        } catch {
            Issue.record("Expected a CloudKit error")
        }

        #expect(operationCount == 2)
        #expect(saveCount == 1)
    }

    @Test
    func deletedZoneIsNotAnAbsentRecord() {
        let error = CKError(.userDeletedZone)
        #expect(!CloudKitErrorClassifier.isMissingItem(error))
    }

    @Test(arguments: [true, false])
    func zoneCreationClearsOldTokenOnlyAfterSuccess(succeeds: Bool) async {
        let manager = makeManager(
            zoneClient: CloudKitZoneClient(
                fetchZone: { _ in throw CKError(.userDeletedZone) },
                saveZone: { _ in
                    if !succeeds { throw CKError(.networkFailure) }
                }
            ),
            initialZoneReady: false
        )
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: manager.changeTokenKey)
        let oldReady = defaults.object(forKey: manager.zoneReadyKey)
        defer {
            defaults.set(oldValue, forKey: manager.changeTokenKey)
            defaults.set(oldReady, forKey: manager.zoneReadyKey)
        }
        let oldToken = Data([1, 2, 3])
        defaults.set(oldToken, forKey: manager.changeTokenKey)
        do {
            try await manager.ensureCustomZone()
            #expect(succeeds)
        } catch {
            #expect(!succeeds)
            #expect((error as? CKError)?.code == .networkFailure)
        }
        #expect(manager.zoneReady == succeeds)
        #expect(defaults.data(forKey: manager.changeTokenKey) == (succeeds ? nil : oldToken))
    }

    @Test
    func disabledInitializationPublishesDisabledState() {
        let syncEnabled = CloudKitSyncEnabledState()
        syncEnabled.value = false
        let manager = CloudKitManager(
            container: CKContainer(
                identifier: CloudKitSyncConstants.cloudKitContainerIdentifier
            ),
            syncEnabled: { syncEnabled.value },
            accountStatus: { .available },
            zoneClient: unusedZoneClient()
        )

        #expect(manager.accountState == .disabled)
        #expect(manager.syncStatus == .disabled)
    }

    @Test
    func disableAndReenableRejectsStaleAccountStatus() async {
        let gate = CloudKitAccountStatusGate()
        let syncEnabled = CloudKitSyncEnabledState()
        let manager = CloudKitManager(
            container: CKContainer(
                identifier: CloudKitSyncConstants.cloudKitContainerIdentifier
            ),
            syncEnabled: { syncEnabled.value },
            accountStatus: { await gate.next() },
            zoneClient: unusedZoneClient()
        )
        #expect(await gate.waitForPendingRequest())

        syncEnabled.value = false
        manager.handleSyncToggle(false)
        #expect(manager.accountState == .disabled)
        #expect(manager.syncStatus == .disabled)

        await gate.resumeNext(with: .available)
        await settleMainActor()
        #expect(manager.accountState == .disabled)
        #expect(manager.syncStatus == .disabled)

        syncEnabled.value = true
        manager.handleSyncToggle(true)
        #expect(manager.accountState == .checking)
        #expect(await gate.waitForPendingRequest())
        await gate.resumeNext(with: .noAccount)

        #expect(await waitUntil { manager.accountState == .noAccount })
        #expect(manager.syncStatus == .offline)
    }

    @Test
    func disableAndReenableRejectsStaleMutationSuccess() async {
        let syncEnabled = CloudKitSyncEnabledState()
        let manager = CloudKitManager(
            container: CKContainer(
                identifier: CloudKitSyncConstants.cloudKitContainerIdentifier
            ),
            syncEnabled: { syncEnabled.value },
            accountStatus: { .available },
            zoneClient: unusedZoneClient(),
            initialZoneReady: true
        )
        #expect(await waitUntil { manager.isAvailable })
        let gate = CloudKitOperationGate()
        let staleMutation = Task {
            try await manager.performCloudKitRecordMutation {
                await gate.wait()
            }
        }
        #expect(await gate.waitUntilBlocked())

        syncEnabled.value = false
        manager.handleSyncToggle(false)
        syncEnabled.value = true
        manager.handleSyncToggle(true)
        await gate.resume()

        do {
            try await staleMutation.value
            Issue.record("Expected stale CloudKit mutation cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(manager.lastSyncDate == nil)
    }

    private func settleMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private func makeManager(
        zoneClient: CloudKitZoneClient,
        initialZoneReady: Bool
    ) -> CloudKitManager {
        CloudKitManager(
            container: CKContainer(
                identifier: CloudKitSyncConstants.cloudKitContainerIdentifier
            ),
            syncEnabled: { false },
            accountStatus: { .available },
            zoneClient: zoneClient,
            initialZoneReady: initialZoneReady
        )
    }

    private func partialMissingZoneError(
        for zoneID: CKRecordZone.ID,
        code: CKError.Code = .zoneNotFound
    ) -> CKError {
        CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [zoneID: CKError(code)]
            ]
        )
    }

    private func unusedZoneClient() -> CloudKitZoneClient {
        CloudKitZoneClient(
            fetchZone: { _ in nil },
            saveZone: { _ in }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
