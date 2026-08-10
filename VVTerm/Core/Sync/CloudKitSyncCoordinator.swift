import Foundation
import CloudKit
import os.log

@MainActor
final class CloudKitSyncCoordinator {
    private let mutationHandler: any PendingCloudKitMutationHandling
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "CloudKitSyncCoordinator"
    )
    private let queue: PendingCloudKitSyncQueue
    private let isSyncEnabled: () -> Bool
    private let now: () -> Date
    private let makeID: () -> UUID
    private var isDraining = false
    private var shouldDrainAgain = false

    init(
        mutationHandler: any PendingCloudKitMutationHandling,
        queue: PendingCloudKitSyncQueue,
        isSyncEnabled: @escaping () -> Bool,
        now: @escaping () -> Date,
        makeID: @escaping () -> UUID
    ) {
        self.mutationHandler = mutationHandler
        self.queue = queue
        self.isSyncEnabled = isSyncEnabled
        self.now = now
        self.makeID = makeID
    }

    func snapshot() -> [PendingCloudKitMutation] {
        queue.snapshot()
    }

    func quarantineSnapshot() -> [PendingCloudKitMutationQuarantine] {
        queue.quarantineSnapshot()
    }

    func remove(_ mutationID: UUID) throws {
        try queue.remove(mutationID)
    }

    func removeAll(
        where shouldRemove: (PendingCloudKitMutation) -> Bool
    ) throws {
        try queue.removeAll(where: shouldRemove)
    }

    func enqueue(_ mutation: PendingCloudKitMutation) throws {
        try queue.enqueue(mutation)
    }

    func enqueue(_ payload: PendingCloudKitMutationPayload) throws {
        try queue.enqueue(
            PendingCloudKitMutation(
                id: makeID(),
                payload: payload,
                createdAt: now()
            )
        )
    }

    func enqueueAtomically(_ mutations: [PendingCloudKitMutation]) throws {
        try queue.enqueueAtomically(mutations)
    }

    func drainPendingMutations() async {
        guard isSyncEnabled() else { return }
        guard !isDraining else {
            shouldDrainAgain = true
            return
        }

        isDraining = true
        defer {
            isDraining = false
            shouldDrainAgain = false
        }

        while true {
            let drainRequestedDuringIteration = shouldDrainAgain
            shouldDrainAgain = false
            let snapshot = queue.snapshot()
            guard !snapshot.isEmpty else { return }

            var didProgress = false
            let orderedMutations = snapshot.sorted(by: PendingCloudKitMutation.drainsBefore)

            for mutation in orderedMutations {
                guard queue.canAttempt(mutation, at: now()) else {
                    continue
                }

                do {
                    try await mutationHandler.handle(mutation)
                } catch is CancellationError {
                    return
                } catch {
                    if isIgnorableDeleteSyncError(error, for: mutation) {
                        guard removePersistedMutation(mutation) else { return }
                        didProgress = true
                        continue
                    }

                    do {
                        try queue.recordFailure(for: mutation, error: error, at: now())
                    } catch {
                        logQueuePersistenceFailure("record pending mutation failure", error: error)
                        return
                    }
                    logger.warning(
                        "Pending CloudKit sync failed for \(mutation.entityDescription): \(error.localizedDescription)"
                    )

                    if shouldPausePendingSyncDrain(for: error) {
                        return
                    }
                    continue
                }

                guard removePersistedMutation(mutation) else { return }
                didProgress = true
            }

            if !didProgress {
                if shouldDrainAgain || drainRequestedDuringIteration {
                    continue
                }
                return
            }
        }
    }

    private func removePersistedMutation(_ mutation: PendingCloudKitMutation) -> Bool {
        do {
            try queue.remove(mutation.id)
            return true
        } catch {
            logQueuePersistenceFailure("remove synchronized mutation", error: error)
            return false
        }
    }

    private func logQueuePersistenceFailure(_ operation: String, error: Error) {
        logger.error("Failed to \(operation): \(error.localizedDescription)")
    }

    private func isIgnorableDeleteSyncError(_ error: Error, for mutation: PendingCloudKitMutation) -> Bool {
        guard mutation.payload.isDelete else { return false }
        guard let ckError = error as? CKError else { return false }

        switch ckError.code {
        case .unknownItem, .zoneNotFound:
            return true
        default:
            return false
        }
    }

    private func shouldPausePendingSyncDrain(for error: Error) -> Bool {
        if let cloudKitError = error as? CloudKitError, cloudKitError == .notAvailable {
            return true
        }

        guard let ckError = error as? CKError else { return false }

        switch ckError.code {
        case .notAuthenticated, .permissionFailure, .quotaExceeded, .requestRateLimited,
             .serviceUnavailable, .networkUnavailable, .networkFailure:
            return true
        default:
            return false
        }
    }
}
