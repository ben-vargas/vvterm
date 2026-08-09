import Foundation
import Combine
import os.log

nonisolated struct StatsPreferencesObserverCleanupRequest: Sendable {
    private let cleanup: @MainActor @Sendable () -> Void

    init(cleanup: @escaping @MainActor @Sendable () -> Void) {
        self.cleanup = cleanup
    }

    func perform() {
        Task { @MainActor in
            cleanup()
        }
    }
}

@MainActor
private final class StatsPreferencesObserverCleanup {
    private let syncLifecycle: any StatsPreferencesSyncLifecycle
    private let resolutionSource: any StatsPreferencesResolutionSource
    private var lifecycleObserverID: UUID?
    private var resolutionObserverID: UUID?

    init(
        syncLifecycle: any StatsPreferencesSyncLifecycle,
        resolutionSource: any StatsPreferencesResolutionSource
    ) {
        self.syncLifecycle = syncLifecycle
        self.resolutionSource = resolutionSource
    }

    var request: StatsPreferencesObserverCleanupRequest {
        StatsPreferencesObserverCleanupRequest { [self] in
            removeObservers()
        }
    }

    func registerLifecycleObserver(_ id: UUID) {
        lifecycleObserverID = id
    }

    func registerResolutionObserver(_ id: UUID) {
        resolutionObserverID = id
    }

    private func removeObservers() {
        if let lifecycleObserverID {
            syncLifecycle.removeObserver(lifecycleObserverID)
            self.lifecycleObserverID = nil
        }
        if let resolutionObserverID {
            resolutionSource.removeStatsPreferencesObserver(resolutionObserverID)
            self.resolutionObserverID = nil
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    @Published private(set) var preferences: StatsPreferences

    private let dependencies: PreferencesStoreDependencies
    private let observerCleanupRequest: StatsPreferencesObserverCleanupRequest
    private let logger = Logger(
        subsystem: "app.vivy.vvterm",
        category: "StatsPreferences"
    )

    private var pendingSyncTask: Task<Void, Never>?
    private var startupSyncTask: Task<Void, Never>?
    private var lifecycleSyncTask: Task<Void, Never>?

    init(dependencies: PreferencesStoreDependencies) {
        self.dependencies = dependencies
        let observerCleanup = StatsPreferencesObserverCleanup(
            syncLifecycle: dependencies.syncLifecycle,
            resolutionSource: dependencies.resolutionSource
        )
        self.observerCleanupRequest = observerCleanup.request
        self.preferences = dependencies.persistence.loadPreferences(
            defaultWriterID: dependencies.writerID
        )

        guard dependencies.startsSynchronization else { return }
        observeSyncEvents(cleanup: observerCleanup)
        startupSyncTask = makeCloudSyncTask()
    }

    deinit {
        pendingSyncTask?.cancel()
        startupSyncTask?.cancel()
        lifecycleSyncTask?.cancel()
        observerCleanupRequest.perform()
    }

    func setStyle(_ style: StatsPreferences.Style) {
        applyMutation { preferences, now in
            preferences.style = style
            preferences.updatedAt = now
            preferences.lastWriterDeviceId = dependencies.writerID
        }
    }

    func setBlockVisibility(_ id: StatsPreferences.BlockID, isVisible: Bool) {
        guard id != .system || isVisible else { return }

        applyMutation { preferences, now in
            var normalized = preferences.normalized()
            guard let blockIndex = normalized.blocks.firstIndex(where: { $0.id == id }) else {
                return
            }

            if !isVisible, normalized.blocks.filter(\.isVisible).count <= 1 {
                return
            }

            normalized.blocks[blockIndex].isVisible = isVisible
            normalized.blocks[blockIndex].updatedAt = now
            normalized.updatedAt = now
            normalized.lastWriterDeviceId = dependencies.writerID
            preferences = normalized
        }
    }

    func moveBlocks(fromOffsets source: IndexSet, toOffset destination: Int) {
        applyMutation { preferences, now in
            var normalized = preferences.normalized()
            var blocks = normalized.orderedBlocks

            blocks.moveElements(fromOffsets: source, toOffset: destination)

            for index in blocks.indices {
                blocks[index].order = index
                blocks[index].updatedAt = now
            }

            normalized.blocks = blocks
            normalized.updatedAt = now
            normalized.lastWriterDeviceId = dependencies.writerID
            preferences = normalized
        }
    }

    func setBlockOrder(_ orderedIDs: [StatsPreferences.BlockID]) {
        applyMutation { preferences, now in
            var normalized = preferences.normalized()
            let currentBlocksByID = Dictionary(uniqueKeysWithValues: normalized.blocks.map { ($0.id, $0) })
            let validIDs = orderedIDs.filter { currentBlocksByID[$0] != nil }
            var finalIDs: [StatsPreferences.BlockID] = []

            for id in validIDs where !finalIDs.contains(id) {
                finalIDs.append(id)
            }
            for block in normalized.orderedBlocks where !finalIDs.contains(block.id) {
                finalIDs.append(block.id)
            }

            var blocks: [StatsPreferences.Block] = []
            for (index, id) in finalIDs.enumerated() {
                guard var block = currentBlocksByID[id] else { continue }
                block.order = index
                block.updatedAt = now
                blocks.append(block)
            }

            normalized.blocks = blocks
            normalized.updatedAt = now
            normalized.lastWriterDeviceId = dependencies.writerID
            preferences = normalized
        }
    }

    private func applyMutation(_ mutate: (inout StatsPreferences, Date) -> Void) {
        var nextPreferences = preferences
        mutate(&nextPreferences, dependencies.now())
        applyPreferences(nextPreferences)
    }

    private func applyPreferences(_ nextPreferences: StatsPreferences, scheduleCloudSync: Bool = true) {
        let normalized = nextPreferences.normalized()
        guard normalized != preferences else { return }

        preferences = normalized
        persistPreferences()

        if scheduleCloudSync {
            scheduleSyncWithCloud()
        }
    }

    private func persistPreferences() {
        dependencies.persistence.savePreferences(preferences)
    }

    private func scheduleSyncWithCloud() {
        pendingSyncTask?.cancel()
        let waitForSyncDebounce = dependencies.waitForSyncDebounce
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        pendingSyncTask = Task { [weak self, waitForSyncDebounce, isSyncEnabled, mutationQueue] in
            try? await waitForSyncDebounce()
            guard !Task.isCancelled else { return }
            guard isSyncEnabled(), let preferences = self?.preferences else { return }
            mutationQueue.enqueueStatsPreferencesUpsert(preferences)
            guard !Task.isCancelled, isSyncEnabled() else { return }
            await mutationQueue.drainPendingMutations()
        }
    }

    private func makeCloudSyncTask() -> Task<Void, Never> {
        let localSnapshot = preferences
        let cloud = dependencies.cloud
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        let logger = logger

        return Task { [weak self, cloud, isSyncEnabled, mutationQueue, logger, localSnapshot] in
            guard !Task.isCancelled, isSyncEnabled() else { return }
            do {
                let cloudResolved = try await cloud.syncStatsPreferences(localSnapshot)
                guard !Task.isCancelled, isSyncEnabled() else { return }
                self?.applyCloudResolution(cloudResolved)
                guard !Task.isCancelled, isSyncEnabled() else { return }
                await mutationQueue.drainPendingMutations()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isSyncEnabled() else { return }
                logger.warning("Stats preferences CloudKit sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyCloudResolution(_ cloudResolved: StatsPreferences) {
        let mergedWithCurrent = StatsPreferences
            .merged(local: preferences, remote: cloudResolved)
            .normalized()
        applyPreferences(mergedWithCurrent, scheduleCloudSync: false)
    }

    private func observeSyncEvents(cleanup: StatsPreferencesObserverCleanup) {
        let lifecycleObserverID = dependencies.syncLifecycle.observe { [weak self] event in
            self?.handleSyncLifecycleEvent(event)
        }
        cleanup.registerLifecycleObserver(lifecycleObserverID)
        let resolutionObserverID = dependencies.resolutionSource.observeStatsPreferences { [weak self] resolvedPreferences in
            guard let self else { return }
            let mergedWithCurrent = StatsPreferences
                .merged(local: self.preferences, remote: resolvedPreferences)
                .normalized()
            self.applyPreferences(mergedWithCurrent, scheduleCloudSync: false)
        }
        cleanup.registerResolutionObserver(resolutionObserverID)
    }

    private func handleSyncLifecycleEvent(_ event: CloudKitSyncLifecycleEvent) {
        switch event {
        case .foreground, .syncEnabled:
            startupSyncTask?.cancel()
            startupSyncTask = nil
            lifecycleSyncTask?.cancel()
            lifecycleSyncTask = makeCloudSyncTask()
        case .syncDisabled:
            pendingSyncTask?.cancel()
            pendingSyncTask = nil
            startupSyncTask?.cancel()
            startupSyncTask = nil
            lifecycleSyncTask?.cancel()
            lifecycleSyncTask = nil
        }
    }
}

private extension Array {
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else { return }

        let movingElements = source.map { self[$0] }
        for index in source.sorted(by: >) {
            remove(at: index)
        }

        let removedBeforeDestination = source.filter { $0 < destination }.count
        let adjustedDestination = Swift.max(0, Swift.min(destination - removedBeforeDestination, count))
        insert(contentsOf: movingElements, at: adjustedDestination)
    }
}
