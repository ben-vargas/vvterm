import CloudKit
import Foundation
import os.log

@MainActor
extension CloudKitManager {
    // MARK: - Account Status

    func refreshAccountStatus() async {
        let generation = cloudKitSyncGeneration
        guard isSyncEnabled else {
            applySyncDisabledState()
            return
        }
        statusStore.accountState = .checking
        await checkAccountStatus(for: generation)
    }

    @discardableResult
    func advanceSyncGeneration() -> UUID {
        let generation = UUID()
        cloudKitSyncGeneration = generation
        accountStatusCheck?.task.cancel()
        accountStatusCheck = nil
        cancelRecordChanges()
        pendingRecordChanges = nil
        return generation
    }

    func cancelRecordChanges() {
        guard let current = inFlightRecordChanges else { return }
        inFlightRecordChanges = nil
        current.task.cancel()
        for waiter in current.waiters.values {
            waiter.resume(with: .failure(CancellationError()))
        }
        for waiter in current.teardownWaiters.values {
            waiter.resume(with: .success(()))
        }
    }

    func isCurrentGeneration(_ generation: UUID) -> Bool {
        isSyncEnabled && cloudKitSyncGeneration == generation
    }

    func requireCurrentGeneration(_ generation: UUID) throws {
        guard isCurrentGeneration(generation) else {
            throw CancellationError()
        }
    }

    // MARK: - Record Zone

    func ensureCustomZone() async throws {
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

    func createZoneIfNeeded() async throws {
        do {
            if try await zoneClient.fetch(recordZoneID) != nil {
                setZoneReady(true)
                return
            }
            logger.warning("CloudKit custom zone was not returned; starting recreation")
        } catch {
            logger.warning(
                "CloudKit zone lookup failed with CKError codes \(CloudKitErrorClassifier.diagnosticCodes(error), privacy: .public)"
            )
            guard CloudKitErrorClassifier.isMissingZone(error) else { throw error }
            logger.warning("CloudKit custom zone is missing; starting recreation")
        }

        do {
            try await zoneClient.save(recordZone)
            // A restored zone cannot use the previous zone's change token.
            clearChangeToken()
            pendingRecordChanges = nil
            setZoneReady(true)
            logger.info("CloudKit custom zone recreation succeeded")
        } catch {
            setZoneReady(false)
            logger.error(
                "CloudKit custom zone recreation failed with CKError codes \(CloudKitErrorClassifier.diagnosticCodes(error), privacy: .public)"
            )
            throw error
        }
    }

    func setZoneReady(_ ready: Bool) {
        zoneReady = ready
        UserDefaults.standard.set(ready, forKey: zoneReadyKey)
    }

    func withZoneRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard CloudKitErrorClassifier.isMissingZone(error) else {
                throw error
            }

            logger.warning("CloudKit zone was missing during operation; recreating and retrying once")
            setZoneReady(false)
            try await ensureCustomZone()
            return try await operation()
        }
    }
}
