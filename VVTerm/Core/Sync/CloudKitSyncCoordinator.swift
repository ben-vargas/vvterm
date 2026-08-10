import Foundation
import CloudKit
import os.log

@MainActor
final class CloudKitSyncCoordinator {
    private let serverCloud: any ServerRemoteMutationClient
    private let terminalThemeCloud: any TerminalThemeCloudMutationClient
    private let terminalAccessoryCloud: any TerminalAccessoryCloudClient
    private let statsPreferencesCloud: any StatsPreferencesCloudClient
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "CloudKitSyncCoordinator"
    )
    private let queue: PendingCloudKitSyncQueue
    private let resolutionHub: CloudKitSyncResolutionHub
    private let isSyncEnabled: () -> Bool
    private let now: () -> Date
    private var isDraining = false
    private var shouldDrainAgain = false

    init(
        serverCloud: any ServerRemoteMutationClient,
        terminalThemeCloud: any TerminalThemeCloudMutationClient,
        terminalAccessoryCloud: any TerminalAccessoryCloudClient,
        statsPreferencesCloud: any StatsPreferencesCloudClient,
        queue: PendingCloudKitSyncQueue,
        resolutionHub: CloudKitSyncResolutionHub,
        isSyncEnabled: @escaping () -> Bool,
        now: @escaping () -> Date
    ) {
        self.serverCloud = serverCloud
        self.terminalThemeCloud = terminalThemeCloud
        self.terminalAccessoryCloud = terminalAccessoryCloud
        self.statsPreferencesCloud = statsPreferencesCloud
        self.queue = queue
        self.resolutionHub = resolutionHub
        self.isSyncEnabled = isSyncEnabled
        self.now = now
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
            try await serverCloud.saveServer(server)
        case .serverDelete(let server):
            try await serverCloud.deleteServer(server)
        case .workspaceUpsert(let workspace):
            try await serverCloud.saveWorkspace(workspace)
        case .workspaceDelete(let workspace):
            try await serverCloud.deleteWorkspace(workspace)
        case .terminalThemeUpsert(let theme):
            try await terminalThemeCloud.saveTerminalTheme(theme)
        case .terminalThemePreferenceUpsert(let preference):
            try await terminalThemeCloud.saveTerminalThemePreference(preference)
        case .terminalAccessoryProfileUpsert(let profile):
            let resolvedProfile = try await terminalAccessoryCloud.syncTerminalAccessoryProfile(
                profile
            )
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
