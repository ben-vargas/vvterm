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
    private var isDraining = false
    private var shouldDrainAgain = false

    init(
        mutationHandler: any PendingCloudKitMutationHandling,
        queue: PendingCloudKitSyncQueue,
        isSyncEnabled: @escaping () -> Bool,
        now: @escaping () -> Date
    ) {
        self.mutationHandler = mutationHandler
        self.queue = queue
        self.isSyncEnabled = isSyncEnabled
        self.now = now
    }

    func snapshot() -> [PendingCloudKitMutation] {
        queue.snapshot()
    }

    func quarantineSnapshot() -> [PendingCloudKitMutationQuarantine] {
        queue.quarantineSnapshot()
    }

    func remove(_ mutationID: UUID) {
        queue.remove(mutationID)
    }

    func removeAll(where shouldRemove: (PendingCloudKitMutation) -> Bool) {
        queue.removeAll(where: shouldRemove)
    }

    func enqueue(_ mutation: PendingCloudKitMutation) {
        queue.enqueue(mutation)
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
                    queue.remove(mutation.id)
                    didProgress = true
                } catch {
                    if isIgnorableDeleteSyncError(error, for: mutation) {
                        queue.remove(mutation.id)
                        didProgress = true
                        continue
                    }

                    queue.recordFailure(for: mutation, error: error)
                    logger.warning(
                        "Pending CloudKit sync failed for \(mutation.entityDescription): \(error.localizedDescription)"
                    )

                    if shouldPausePendingSyncDrain(for: error) {
                        return
                    }
                }
            }

            if !didProgress {
                if shouldDrainAgain || drainRequestedDuringIteration {
                    continue
                }
                return
            }
        }
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
