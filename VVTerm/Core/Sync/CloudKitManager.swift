import CloudKit
import Foundation
import Combine
import os.log

// MARK: - CloudKit Manager

@MainActor
final class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()

    typealias SyncStatus = CloudKitSyncState.Status

    @Published private(set) var syncState = CloudKitSyncState()
    @Published var lastSyncDate: Date?
    @Published private(set) var accountState: CloudKitAccountState = .checking

    var syncStatus: SyncStatus { syncState.status }
    var isAvailable: Bool { syncState.isAvailable }

    private let container: CKContainer
    private let database: CKDatabase
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CloudKit")
    private let recordZoneName = CloudKitSyncConstants.recordZoneName
    private lazy var recordZone = CKRecordZone(zoneName: recordZoneName)
    private var recordZoneID: CKRecordZone.ID { recordZone.zoneID }
    private var changeTokenKey: String { CloudKitSyncConstants.changeTokenKey(for: recordZoneName) }
    private var zoneReadyKey: String { CloudKitSyncConstants.zoneReadyKey(for: recordZoneName) }

    private var accountStatusChecked = false
    private var isSyncEnabled: Bool { SyncSettings.isEnabled }
    private struct InFlightRecordChanges {
        let id: UUID
        let identity: CloudKitRecordChangeFetchIdentity
        let task: Task<CloudKitRawRecordChanges, Error>
    }

    private var inFlightRecordChanges: InFlightRecordChanges?
    private var ensureZoneTask: Task<Void, Error>?
    private var zoneReady: Bool

    private init() {
        container = CKContainer(identifier: CloudKitSyncConstants.cloudKitContainerIdentifier)
        database = container.privateCloudDatabase
        zoneReady = UserDefaults.standard.bool(forKey: CloudKitSyncConstants.zoneReadyKey(for: recordZoneName))
        Task { await checkAccountStatus() }
    }

    // MARK: - Account Status

    /// Ensures account status is checked before performing operations
    private func ensureAccountStatusChecked() async {
        guard isSyncEnabled else {
            applySyncDisabledState()
            accountStatusChecked = true
            return
        }
        // Re-check when unavailable so transient account/network states can recover
        guard !accountStatusChecked || !isAvailable else { return }
        await checkAccountStatus()
    }

    private func checkAccountStatus() async {
        guard isSyncEnabled else {
            applySyncDisabledState()
            accountStatusChecked = true
            return
        }

        do {
            let status = try await container.accountStatus()
            let resolvedAccountState: CloudKitAccountState = switch status {
            case .available:
                .available
            case .noAccount:
                .noAccount
            case .restricted:
                .restricted
            case .couldNotDetermine:
                .couldNotDetermine
            case .temporarilyUnavailable:
                .temporarilyUnavailable
            @unknown default:
                .unknown(rawValue: status.rawValue)
            }
            let statusLogValue = String(describing: resolvedAccountState)

            logger.info("CloudKit account status: \(statusLogValue)")
            logger.info("Container identifier: \(self.container.containerIdentifier ?? "nil")")

            accountState = resolvedAccountState
            accountStatusChecked = true
            if status == .available {
                syncState.markAvailable()
            } else {
                syncState.markOffline()
                logger.warning("CloudKit not available. Status: \(statusLogValue)")
            }
        } catch {
            logger.error("CloudKit account status check failed: \(error.localizedDescription)")
            accountState = .failed(detail: error.localizedDescription)
            syncState.markAccountFailure(error.localizedDescription)
            accountStatusChecked = true
        }
    }

    private func applySyncDisabledState() {
        syncState.markDisabled()
        accountState = .disabled
    }

    func handleSyncToggle(_ enabled: Bool) {
        if enabled {
            accountStatusChecked = false
            Task {
                await checkAccountStatus()
                await subscribeToChanges()
            }
        } else {
            applySyncDisabledState()
        }
    }

    // MARK: - Change Fetching (Incremental, No Queries)

    func fetchCloudKitRecordChanges(
        forceFullFetch: Bool,
        desiredKeys: [String]
    ) async throws -> CloudKitRawRecordChanges {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        let fetchIdentity = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: forceFullFetch,
            desiredKeys: desiredKeys
        )
        let requestDecision = try CloudKitRecordChangeRequestPolicy.decision(
            for: fetchIdentity,
            inFlight: inFlightRecordChanges?.identity
        )
        if requestDecision == .coalesce, let inFlightRecordChanges {
            return try await inFlightRecordChanges.task.value
        }

        let taskID = UUID()
        let task = Task {
            try await self.withZoneRetry {
                try await self.fetchRecordChangesFromCloudKit(
                    forceFullFetch: forceFullFetch,
                    desiredKeys: desiredKeys
                )
            }
        }
        inFlightRecordChanges = InFlightRecordChanges(
            id: taskID,
            identity: fetchIdentity,
            task: task
        )
        defer {
            if inFlightRecordChanges?.id == taskID {
                inFlightRecordChanges = nil
            }
        }

        return try await task.value
    }

    private func fetchRecordChangesFromCloudKit(
        forceFullFetch: Bool,
        desiredKeys: [String]
    ) async throws -> CloudKitRawRecordChanges {
        try await performSyncOperation {
            try await fetchTrackedRecordChangesFromCloudKit(
                forceFullFetch: forceFullFetch,
                desiredKeys: desiredKeys
            )
        }
    }

    private func fetchTrackedRecordChangesFromCloudKit(
        forceFullFetch: Bool,
        desiredKeys: [String]
    ) async throws -> CloudKitRawRecordChanges {
        let previousToken = forceFullFetch ? nil : loadChangeToken()

        do {
            let changes = try await fetchRawRecordChangesFromCloudKit(
                previousToken: previousToken,
                isFullFetch: forceFullFetch || previousToken == nil,
                desiredKeys: desiredKeys
            )
            lastSyncDate = Date()
            logger.info(
                "Fetched \(changes.changes.count) raw CloudKit changes (full fetch: \(changes.isFullFetch))"
            )
            return changes
        } catch {
            if isChangeTokenExpired(error) {
                logger.warning("CloudKit change token expired; resetting and performing full fetch")
                clearChangeToken()
                let changes = try await fetchRawRecordChangesFromCloudKit(
                    previousToken: nil,
                    isFullFetch: true,
                    desiredKeys: desiredKeys
                )
                lastSyncDate = Date()
                return changes
            }

            logger.error("Failed to fetch changes: \(error.localizedDescription)")
            throw error
        }
    }

    private func fetchRawRecordChangesFromCloudKit(
        previousToken: CKServerChangeToken?,
        isFullFetch: Bool,
        desiredKeys: [String]
    ) async throws -> CloudKitRawRecordChanges {
        let zoneID = recordZoneID
        var token = previousToken
        var moreComing = true

        var budget = CloudKitSyncBudget()
        var changes: [CloudKitRawRecordChange] = []

        while moreComing {
            try budget.requireCapacityForNextPage()
            let batch = try await fetchZoneChanges(
                zoneID: zoneID,
                previousToken: token,
                budget: budget,
                desiredKeys: desiredKeys
            )
            try budget.recordBatch(
                records: batch.records.count,
                deletions: batch.deletions.count,
                aggregateBytes: batch.recordByteCount
            )

            for record in batch.records {
                changes.append(.record(record))
            }

            for deletion in batch.deletions {
                changes.append(
                    .deletion(
                        recordID: deletion.recordID,
                        recordType: deletion.recordType
                    )
                )
            }

            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        if let token = token {
            saveChangeToken(token)
        }

        return CloudKitRawRecordChanges(
            changes: changes,
            isFullFetch: isFullFetch
        )
    }

    private func prepareSyncMutation() async throws {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }
        try await ensureCustomZone()
    }

    private func performSyncOperation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        let operationID = UUID()
        guard syncState.beginOperation(operationID) else {
            throw CloudKitError.notAvailable
        }

        do {
            let result = try await operation()
            syncState.completeOperation(operationID, with: .success)
            return result
        } catch {
            logger.error("CloudKit sync operation failed: \(error.localizedDescription)")
            syncState.completeOperation(operationID, with: .failure(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Raw Record Transport

    var cloudKitRecordZoneID: CKRecordZone.ID {
        recordZoneID
    }

    var isCloudKitAvailable: Bool {
        isAvailable
    }

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await prepareSyncMutation()
        return try await performSyncOperation(operation)
    }

    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }
        try await ensureCustomZone()
        return try await withZoneRetry {
            try await fetchAllRecordsFromCloudKit(
                matchingRecordTypes: recordTypes,
                desiredKeys: desiredKeys
            )
        }
    }

    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }
        try await ensureCustomZone()
        return try await withZoneRetry {
            try await database.record(for: recordID)
        }
    }

    func upsertCloudKitRecord(_ record: CKRecord) async throws {
        try await withZoneRetry {
            try await saveRecordWithUpsert(record)
        }
    }

    func deleteCloudKitRecord(_ recordID: CKRecord.ID) async throws {
        _ = try await withZoneRetry {
            try await database.modifyRecords(saving: [], deleting: [recordID])
        }
    }

    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws {
        try await withZoneRetry {
            try await saveRecord(record, savePolicy: .ifServerRecordUnchanged)
        }
    }

    func markCloudKitRecordSynchronized() {
        lastSyncDate = Date()
    }

    func cloudKitServerRecord(from error: Error) -> CKRecord? {
        extractServerRecord(from: error)
    }

    func isCloudKitRecordMissing(_ error: Error) -> Bool {
        isUnknownItemError(error)
    }

    // MARK: - Subscriptions

    func subscribeToChanges() async {
        await ensureAccountStatusChecked()
        guard isSyncEnabled, isAvailable else { return }

        let subscriptionID = CloudKitSyncConstants.databaseSubscriptionID

        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true

        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        subscription.notificationInfo = notification

        do {
            if let existing = try? await database.subscription(for: subscriptionID) as? CKDatabaseSubscription,
               existing.notificationInfo?.shouldSendContentAvailable == true {
                logger.debug("CloudKit database subscription already configured")
                return
            }

            try await database.save(subscription)
            logger.info("Subscribed to database changes")
        } catch {
            logger.error("Failed to subscribe to database changes: \(error.localizedDescription)")
        }
    }

    // MARK: - Record Fetching (No Queries)

    private struct ZoneChangeBatch {
        let records: [CKRecord]
        let deletions: [Deletion]
        let recordByteCount: Int
        let serverChangeToken: CKServerChangeToken?
        let moreComing: Bool
    }

    private struct Deletion {
        let recordID: CKRecord.ID
        let recordType: CKRecord.RecordType
    }

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: changeTokenKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else {
            return
        }
        UserDefaults.standard.set(data, forKey: changeTokenKey)
    }

    private func clearChangeToken() {
        UserDefaults.standard.removeObject(forKey: changeTokenKey)
    }

    private func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .changeTokenExpired
    }

    private func fetchAllRecordsFromCloudKit(
        matchingRecordTypes recordTypes: Set<String>? = nil,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        try await ensureCustomZone()
        let zoneID = recordZoneID
        var token: CKServerChangeToken?
        var recordsByID: [String: CKRecord] = [:]
        var moreComing = true
        var budget = CloudKitSyncBudget()

        while moreComing {
            try budget.requireCapacityForNextPage()
            let batch = try await fetchZoneChanges(
                zoneID: zoneID,
                previousToken: token,
                budget: budget,
                desiredKeys: desiredKeys
            )
            try budget.recordBatch(
                records: batch.records.count,
                deletions: batch.deletions.count,
                aggregateBytes: batch.recordByteCount
            )
            for record in batch.records where recordTypes?.contains(record.recordType) != false {
                recordsByID[recordKey(record.recordID, recordType: record.recordType)] = record
            }
            for deletion in batch.deletions {
                recordsByID.removeValue(
                    forKey: recordKey(deletion.recordID, recordType: deletion.recordType)
                )
            }
            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        return Array(recordsByID.values)
    }

    private func fetchZoneChanges(
        zoneID: CKRecordZone.ID,
        previousToken: CKServerChangeToken?,
        budget: CloudKitSyncBudget,
        desiredKeys: [String]
    ) async throws -> ZoneChangeBatch {
        let logger = logger
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ZoneChangeBatch, Error>) in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousToken,
                resultsLimit: min(200, budget.remainingRecords, budget.remainingDeletions),
                desiredKeys: desiredKeys
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            operation.qualityOfService = .userInitiated

            var records: [CKRecord] = []
            var deletions: [Deletion] = []
            var recordByteCount = 0
            var serverChangeToken: CKServerChangeToken?
            var moreComing = false
            var zoneError: Error?

            operation.recordWasChangedBlock = { recordID, recordResult in
                guard zoneError == nil else { return }
                switch recordResult {
                case .success(let record):
                    do {
                        guard records.count < budget.remainingRecords else {
                            throw CloudKitSyncBudgetError.tooManyRecords
                        }
                        let bytes = try CloudKitRecordSizer.byteCount(
                            of: record,
                            limits: budget.limits
                        )
                        let (newByteCount, overflow) = recordByteCount.addingReportingOverflow(bytes)
                        guard !overflow, newByteCount <= budget.remainingBytes else {
                            throw CloudKitSyncBudgetError.aggregateDataTooLarge
                        }
                        recordByteCount = newByteCount
                        records.append(record)
                    } catch {
                        zoneError = error
                        operation.cancel()
                    }
                case .failure(let error):
                    logger.error(
                        "Failed to fetch record \(recordID.recordName): \(error.localizedDescription)"
                    )
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                guard zoneError == nil else { return }
                guard deletions.count < budget.remainingDeletions else {
                    zoneError = CloudKitSyncBudgetError.tooManyDeletions
                    operation.cancel()
                    return
                }
                deletions.append(Deletion(recordID: recordID, recordType: recordType))
            }

            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let info):
                    serverChangeToken = info.serverChangeToken
                    moreComing = info.moreComing
                case .failure(let error):
                    if zoneError == nil {
                        zoneError = error
                    }
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    if let zoneError = zoneError {
                        continuation.resume(throwing: zoneError)
                    } else {
                        continuation.resume(
                            returning: ZoneChangeBatch(
                                records: records,
                                deletions: deletions,
                                recordByteCount: recordByteCount,
                                serverChangeToken: serverChangeToken,
                                moreComing: moreComing
                            )
                        )
                    }
                case .failure(let error):
                    continuation.resume(throwing: zoneError ?? error)
                }
            }

            self.database.add(operation)
        }
    }

    private func extractServerRecord(from error: Error) -> CKRecord? {
        guard let ckError = error as? CKError else { return nil }

        if ckError.code == .serverRecordChanged {
            return ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for partialError in partialErrors.values {
                if let serverRecord = extractServerRecord(from: partialError) {
                    return serverRecord
                }
            }
        }

        return nil
    }

    private func isUnknownItemError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }

        if ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            return true
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            return partialErrors.values.contains { isUnknownItemError($0) }
        }

        return false
    }

    // MARK: - Upsert Helper

    /// Save a record using CKModifyRecordsOperation with changedKeys policy
    /// This handles both insert (new record) and update (existing record)
    private func saveRecordWithUpsert(_ record: CKRecord) async throws {
        try await saveRecord(record, savePolicy: .changedKeys)
    }

    private func saveRecord(
        _ record: CKRecord,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = savePolicy
            operation.qualityOfService = .userInitiated

            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    private func recordKey(
        _ recordID: CKRecord.ID,
        recordType: CKRecord.RecordType
    ) -> String {
        "\(recordType):\(recordID.recordName)"
    }

    // MARK: - Force Sync

    func forceSync() async {
        lastSyncDate = nil
        accountStatusChecked = false
        clearChangeToken()
        await checkAccountStatus()
    }

    // MARK: - Record Zone

    private func ensureCustomZone() async throws {
        if zoneReady {
            return
        }

        if let task = ensureZoneTask {
            try await task.value
            return
        }

        let task = Task { try await self.createZoneIfNeeded() }
        ensureZoneTask = task
        defer { ensureZoneTask = nil }
        try await task.value
    }

    private func createZoneIfNeeded() async throws {
        let results = try await database.recordZones(for: [recordZoneID])
        if let result = results[recordZoneID] {
            switch result {
            case .success:
                setZoneReady(true)
                return
            case .failure(let error):
                if isZoneNotFound(error) {
                    _ = try await database.modifyRecordZones(saving: [recordZone], deleting: [])
                    setZoneReady(true)
                    return
                }
                throw error
            }
        }

        _ = try await database.modifyRecordZones(saving: [recordZone], deleting: [])
        setZoneReady(true)
    }

    private func setZoneReady(_ ready: Bool) {
        zoneReady = ready
        UserDefaults.standard.set(ready, forKey: zoneReadyKey)
    }

    private func withZoneRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isZoneNotFound(error) else {
                throw error
            }

            logger.warning("CloudKit zone was missing during operation; recreating and retrying once")
            setZoneReady(false)
            try await ensureCustomZone()
            return try await operation()
        }
    }

    private func isZoneNotFound(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .zoneNotFound || ckError.code == .unknownItem
    }
}

// MARK: - CloudKit Error

enum CloudKitError: LocalizedError {
    case notAvailable
    case recordNotFound
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "iCloud is not available"
        case .recordNotFound: return "Record not found"
        case .encodingFailed: return "Failed to encode data"
        case .decodingFailed: return "Failed to decode data"
        }
    }
}
