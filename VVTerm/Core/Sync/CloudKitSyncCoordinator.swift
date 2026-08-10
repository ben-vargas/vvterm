import Foundation
import CloudKit
import os.log

@MainActor
final class CloudKitSyncCoordinator {
    private let cloudKit: CloudKitManager
    private let statsPreferencesCloud: any StatsPreferencesCloudClient
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "CloudKitSyncCoordinator"
    )
    private let queue = PendingCloudKitSyncQueue()
    private let resolutionHub = CloudKitSyncResolutionHub.shared
    private var isDraining = false
    private var shouldDrainAgain = false

    init(
        cloudKit: CloudKitManager,
        statsPreferencesCloud: any StatsPreferencesCloudClient
    ) {
        self.cloudKit = cloudKit
        self.statsPreferencesCloud = statsPreferencesCloud
    }

    func snapshot() -> [PendingCloudKitMutation] {
        queue.snapshot()
    }

    func quarantineSnapshot() -> [PendingCloudKitMutationQuarantine] {
        queue.quarantineSnapshot()
    }

    func clearPendingMutations() {
        queue.removeAll()
    }

    func clearPendingServerAndWorkspaceMutations() {
        queue.removeAll { $0.payload.isServerOrWorkspace }
    }

    func removePendingMutation(_ mutationID: UUID) {
        queue.remove(mutationID)
    }

    func enqueueServerUpsert(_ server: Server) {
        queue.enqueue(.serverUpsert(server))
    }

    func enqueueServerDelete(_ server: Server) {
        queue.enqueue(.serverDelete(server))
    }

    func enqueueWorkspaceUpsert(_ workspace: Workspace) {
        queue.enqueue(.workspaceUpsert(workspace))
    }

    func enqueueWorkspaceDelete(_ workspace: Workspace) {
        queue.enqueue(.workspaceDelete(workspace))
    }

    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme) {
        queue.enqueue(.terminalThemeUpsert(theme))
    }

    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference) {
        queue.enqueue(.terminalThemePreferenceUpsert(preference))
    }

    func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile) {
        queue.enqueue(.terminalAccessoryProfileUpsert(profile))
    }

    func enqueueStatsPreferencesUpsert(_ preferences: StatsPreferences) {
        queue.enqueue(.statsPreferencesUpsert(preferences))
    }

    func enqueueMutationsAtomically(_ mutations: [PendingCloudKitMutation]) throws {
        try queue.enqueueAtomically(mutations)
    }

    func drainPendingMutations() async {
        guard SyncSettings.isEnabled else { return }
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
                guard queue.canAttempt(mutation, at: Date()) else {
                    continue
                }

                do {
                    try await syncPendingMutation(mutation)
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

    private func syncPendingMutation(_ mutation: PendingCloudKitMutation) async throws {
        switch mutation.payload {
        case .serverUpsert(let server):
            try await cloudKit.saveServer(server)
        case .serverDelete(let server):
            try await cloudKit.deleteServer(server)
        case .workspaceUpsert(let workspace):
            try await cloudKit.saveWorkspace(workspace)
        case .workspaceDelete(let workspace):
            try await cloudKit.deleteWorkspace(workspace)
        case .terminalThemeUpsert(let theme):
            try await cloudKit.saveTerminalTheme(theme)
        case .terminalThemePreferenceUpsert(let preference):
            try await cloudKit.saveTerminalThemePreference(preference)
        case .terminalAccessoryProfileUpsert(let profile):
            let resolvedProfile = try await cloudKit.syncTerminalAccessoryProfile(profile)
            resolutionHub.publish(.terminalAccessoryProfile(resolvedProfile))
        case .statsPreferencesUpsert(let preferences):
            let resolvedPreferences = try await statsPreferencesCloud.syncStatsPreferences(
                preferences
            )
            resolutionHub.publish(.statsPreferences(resolvedPreferences))
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
