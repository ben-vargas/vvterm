import Foundation
import Combine
import os.log

@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()
    static let defaultsKey = CloudKitSyncConstants.statsPreferencesStorageKey

    @Published private(set) var preferences: StatsPreferences

    private let defaults: UserDefaults
    private let cloudKit: CloudKitManager
    private let syncCoordinator = CloudKitSyncCoordinator.shared
    private let syncLifecycle: CloudKitSyncLifecycleDriver
    private let syncResolutionHub: CloudKitSyncResolutionHub
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "StatsPreferences"
    )

    private var syncLifecycleObserverID: UUID?
    private var syncResolutionObserverID: UUID?
    private var pendingSyncTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        cloudKit: CloudKitManager? = nil,
        syncLifecycle: CloudKitSyncLifecycleDriver? = nil,
        syncResolutionHub: CloudKitSyncResolutionHub? = nil
    ) {
        self.defaults = defaults
        self.cloudKit = cloudKit ?? CloudKitManager.shared
        self.syncLifecycle = syncLifecycle ?? .shared
        self.syncResolutionHub = syncResolutionHub ?? .shared
        self.preferences = PreferencesStore.loadPreferences(from: defaults)

        observeSyncEvents()

        Task {
            await syncWithCloud()
            await syncCoordinator.drainPendingMutations()
        }
    }

    deinit {
        if let syncLifecycleObserverID {
            let syncLifecycle = syncLifecycle
            Task { @MainActor in
                syncLifecycle.removeObserver(syncLifecycleObserverID)
            }
        }
        if let syncResolutionObserverID {
            let syncResolutionHub = syncResolutionHub
            Task { @MainActor in
                syncResolutionHub.removeObserver(syncResolutionObserverID)
            }
        }
        pendingSyncTask?.cancel()
    }

    func setStyle(_ style: StatsPreferences.Style) {
        applyMutation { preferences, now in
            preferences.style = style
            preferences.updatedAt = now
            preferences.lastWriterDeviceId = DeviceIdentity.id
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
            normalized.lastWriterDeviceId = DeviceIdentity.id
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
            normalized.lastWriterDeviceId = DeviceIdentity.id
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
            normalized.lastWriterDeviceId = DeviceIdentity.id
            preferences = normalized
        }
    }

    private func applyMutation(_ mutate: (inout StatsPreferences, Date) -> Void) {
        var nextPreferences = preferences
        mutate(&nextPreferences, Date())
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
        do {
            let encoded = try JSONEncoder().encode(preferences)
            defaults.set(encoded, forKey: Self.defaultsKey)
        } catch {
            logger.error("Failed to encode stats preferences: \(error.localizedDescription)")
        }
    }

    private static func loadPreferences(from defaults: UserDefaults) -> StatsPreferences {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            let defaultPreferences = StatsPreferences
                .defaultValue(lastWriterDeviceId: DeviceIdentity.id)
                .normalized()
            if let encoded = try? JSONEncoder().encode(defaultPreferences) {
                defaults.set(encoded, forKey: Self.defaultsKey)
            }
            return defaultPreferences
        }

        do {
            var decoded = try JSONDecoder().decode(StatsPreferences.self, from: data)
            if decoded.lastWriterDeviceId.isEmpty {
                decoded.lastWriterDeviceId = DeviceIdentity.id
            }
            let normalized = decoded.normalized()
            if normalized != decoded, let encoded = try? JSONEncoder().encode(normalized) {
                defaults.set(encoded, forKey: Self.defaultsKey)
            }
            return normalized
        } catch {
            let defaultPreferences = StatsPreferences
                .defaultValue(lastWriterDeviceId: DeviceIdentity.id)
                .normalized()
            if let encoded = try? JSONEncoder().encode(defaultPreferences) {
                defaults.set(encoded, forKey: Self.defaultsKey)
            }
            return defaultPreferences
        }
    }

    private func scheduleSyncWithCloud() {
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await self?.enqueuePreferencesSync()
        }
    }

    private func enqueuePreferencesSync() async {
        guard SyncSettings.isEnabled else { return }
        syncCoordinator.enqueueStatsPreferencesUpsert(preferences)
        await syncCoordinator.drainPendingMutations()
    }

    private func syncWithCloud() async {
        guard SyncSettings.isEnabled else { return }

        do {
            let cloudResolved = try await cloudKit.syncStatsPreferences(preferences)
            let mergedWithCurrent = StatsPreferences.merged(local: preferences, remote: cloudResolved).normalized()
            applyPreferences(mergedWithCurrent, scheduleCloudSync: false)
        } catch {
            logger.warning("Stats preferences CloudKit sync failed: \(error.localizedDescription)")
        }
    }

    private func observeSyncEvents() {
        syncLifecycleObserverID = syncLifecycle.observe { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .foreground, .syncEnabled:
                    await self.syncWithCloud()
                    await self.syncCoordinator.drainPendingMutations()
                case .syncDisabled:
                    self.pendingSyncTask?.cancel()
                    self.pendingSyncTask = nil
                }
            }
        }
        syncResolutionObserverID = syncResolutionHub.observe { [weak self] resolution in
            guard let self, case .statsPreferences(let resolvedPreferences) = resolution else {
                return
            }
            let mergedWithCurrent = StatsPreferences
                .merged(local: self.preferences, remote: resolvedPreferences)
                .normalized()
            self.applyPreferences(mergedWithCurrent, scheduleCloudSync: false)
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
