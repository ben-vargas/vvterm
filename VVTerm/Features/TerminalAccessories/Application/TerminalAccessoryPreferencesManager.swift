import Foundation
import Combine
import os.log

nonisolated struct TerminalAccessoryObserverCleanupRequest: Sendable {
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
private final class TerminalAccessoryObserverCleanup {
    private let syncLifecycle: any TerminalAccessorySyncLifecycle
    private let resolutionSource: any TerminalAccessoryResolutionSource
    private var lifecycleObserverID: UUID?
    private var resolutionObserverID: UUID?

    init(
        syncLifecycle: any TerminalAccessorySyncLifecycle,
        resolutionSource: any TerminalAccessoryResolutionSource
    ) {
        self.syncLifecycle = syncLifecycle
        self.resolutionSource = resolutionSource
    }

    var request: TerminalAccessoryObserverCleanupRequest {
        TerminalAccessoryObserverCleanupRequest { [self] in
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
            resolutionSource.removeTerminalAccessoryProfileObserver(resolutionObserverID)
            self.resolutionObserverID = nil
        }
    }
}

@MainActor
final class TerminalAccessoryPreferencesManager: ObservableObject {
    @Published private(set) var profile: TerminalAccessoryProfile

    private let dependencies: TerminalAccessoryPreferencesDependencies
    private let observerCleanupRequest: TerminalAccessoryObserverCleanupRequest
    private let logger = Logger(
        subsystem: "app.vivy.vvterm",
        category: "TerminalAccessoryPreferences"
    )

    private var pendingSyncTask: Task<Void, Never>?
    private var startupSyncTask: Task<Void, Never>?
    private var lifecycleSyncTask: Task<Void, Never>?

    private var defaults: UserDefaults { dependencies.defaults }

    init(dependencies: TerminalAccessoryPreferencesDependencies) {
        self.dependencies = dependencies
        let observerCleanup = TerminalAccessoryObserverCleanup(
            syncLifecycle: dependencies.syncLifecycle,
            resolutionSource: dependencies.resolutionSource
        )
        self.observerCleanupRequest = observerCleanup.request
        self.profile = TerminalAccessoryPreferencesManager.loadProfile(
            from: dependencies.defaults,
            key: dependencies.persistenceKey,
            writerID: dependencies.writerID
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

    var activeItems: [TerminalAccessoryItemRef] {
        profile.layout.activeItems
    }

    var customActions: [TerminalAccessoryCustomAction] {
        profile.customActions
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var deletedCustomActions: [TerminalAccessoryCustomAction] {
        profile.customActions.filter(\.isDeleted)
    }

    var canCreateCustomAction: Bool {
        customActions.count < TerminalAccessoryProfile.maxCustomActions
    }

    /// Free tier is limited to `FreeTierLimits.maxCustomActions` created actions.
    /// Existing actions beyond the limit keep working; only creation is gated.
    func isCustomActionCreationProGated(hasProAccess: Bool) -> Bool {
        !hasProAccess && customActions.count >= FreeTierLimits.maxCustomActions
    }

    func customActionLimit(hasProAccess: Bool) -> Int {
        hasProAccess ? TerminalAccessoryProfile.maxCustomActions : FreeTierLimits.maxCustomActions
    }

    func customAction(for id: UUID) -> TerminalAccessoryCustomAction? {
        customActions.first { $0.id == id }
    }

    func createCustomAction(
        title: String,
        kind: TerminalAccessoryCustomActionKind,
        commandContent: String,
        commandSendMode: TerminalSnippetSendMode,
        shortcutKey: TerminalAccessoryShortcutKey,
        shortcutModifiers: TerminalAccessoryShortcutModifiers,
        hasProAccess: Bool
    ) throws -> TerminalAccessoryCustomAction {
        guard canCreateCustomAction else {
            throw TerminalAccessoryValidationError.customActionLimitReached
        }
        guard !isCustomActionCreationProGated(hasProAccess: hasProAccess) else {
            throw TerminalAccessoryValidationError.customActionProRequired
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommandContent = commandContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TerminalAccessoryValidationError.emptyTitle
        }
        if kind == .command && trimmedCommandContent.isEmpty {
            throw TerminalAccessoryValidationError.emptyCommandContent
        }

        let now = dependencies.now()
        let action = TerminalAccessoryCustomAction(
            id: dependencies.makeID(),
            title: String(trimmedTitle.prefix(TerminalAccessoryProfile.maxCustomActionTitleLength)),
            kind: kind,
            commandContent: kind == .command
                ? String(commandContent.prefix(TerminalAccessoryProfile.maxCommandContentLength))
                : "",
            commandSendMode: commandSendMode,
            shortcutKey: shortcutKey,
            shortcutModifiers: shortcutModifiers,
            updatedAt: now,
            deletedAt: nil
        )

        applyProfileMutation(at: now) { nextProfile, _ in
            nextProfile.customActions.insert(action, at: 0)
        }
        dependencies.trackCustomActionCreated(kind)
        return action
    }

    @discardableResult
    func updateCustomAction(
        id: UUID,
        title: String,
        kind: TerminalAccessoryCustomActionKind,
        commandContent: String,
        commandSendMode: TerminalSnippetSendMode,
        shortcutKey: TerminalAccessoryShortcutKey,
        shortcutModifiers: TerminalAccessoryShortcutModifiers
    ) throws -> TerminalAccessoryCustomAction {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommandContent = commandContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TerminalAccessoryValidationError.emptyTitle
        }
        if kind == .command && trimmedCommandContent.isEmpty {
            throw TerminalAccessoryValidationError.emptyCommandContent
        }

        guard let index = profile.customActions.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TerminalAccessoryValidationError.customActionNotFound
        }

        let now = dependencies.now()
        applyProfileMutation(at: now) { nextProfile, mutationDate in
            nextProfile.customActions[index].title = String(trimmedTitle.prefix(TerminalAccessoryProfile.maxCustomActionTitleLength))
            nextProfile.customActions[index].kind = kind
            nextProfile.customActions[index].commandContent = kind == .command
                ? String(commandContent.prefix(TerminalAccessoryProfile.maxCommandContentLength))
                : ""
            nextProfile.customActions[index].commandSendMode = commandSendMode
            nextProfile.customActions[index].shortcutKey = shortcutKey
            nextProfile.customActions[index].shortcutModifiers = shortcutModifiers
            nextProfile.customActions[index].updatedAt = mutationDate
            nextProfile.customActions[index].deletedAt = nil
        }
        let nextProfile = profile
        return nextProfile.customActions[index]
    }

    func deleteCustomAction(id: UUID) {
        guard let index = profile.customActions.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }

        applyProfileMutation { nextProfile, now in
            nextProfile.customActions[index].title = ""
            nextProfile.customActions[index].commandContent = ""
            nextProfile.customActions[index].deletedAt = now
            nextProfile.customActions[index].updatedAt = now
        }
    }

    func moveActiveItems(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let nextItems = moveItems(profile.layout.activeItems, fromOffsets: offsets, toOffset: destination)
        updateLayoutItems(nextItems)
    }

    func removeActiveItems(atOffsets offsets: IndexSet) {
        let nextItems = removeItems(profile.layout.activeItems, atOffsets: offsets)
        updateLayoutItems(nextItems)
    }

    func removeActiveItem(_ item: TerminalAccessoryItemRef) {
        var nextItems = profile.layout.activeItems
        nextItems.removeAll { $0 == item }
        updateLayoutItems(nextItems)
    }

    func addActiveItem(_ item: TerminalAccessoryItemRef) {
        guard !profile.layout.activeItems.contains(item) else { return }
        var nextItems = profile.layout.activeItems
        nextItems.append(item)
        updateLayoutItems(nextItems)
    }

    func resetToDefaultLayout() {
        updateLayout { layout in
            layout.activeItems = TerminalAccessoryProfile.defaultActiveItems
        }
    }

    func refreshFromCloud() async {
        startupSyncTask?.cancel()
        startupSyncTask = nil
        lifecycleSyncTask?.cancel()
        let task = makeCloudSyncTask()
        lifecycleSyncTask = task
        await task.value
    }

    private func updateLayoutItems(_ items: [TerminalAccessoryItemRef]) {
        updateLayout { layout in
            layout.activeItems = items
        }
    }

    private func moveItems<T>(_ items: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        var result = items
        let movingItems = offsets.map { result[$0] }
        for index in offsets.sorted(by: >) {
            result.remove(at: index)
        }

        var insertionIndex = destination
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        insertionIndex -= removedBeforeDestination
        insertionIndex = max(0, min(insertionIndex, result.count))
        result.insert(contentsOf: movingItems, at: insertionIndex)
        return result
    }

    private func removeItems<T>(_ items: [T], atOffsets offsets: IndexSet) -> [T] {
        var result = items
        for index in offsets.sorted(by: >) {
            guard result.indices.contains(index) else { continue }
            result.remove(at: index)
        }
        return result
    }

    private func updateLayout(_ update: (inout TerminalAccessoryLayout) -> Void) {
        applyProfileMutation { nextProfile, now in
            update(&nextProfile.layout)
            nextProfile.layout.updatedAt = now
        }
    }

    private func applyProfileMutation(
        at mutationDate: Date? = nil,
        scheduleCloudSync: Bool = true,
        _ mutate: (inout TerminalAccessoryProfile, Date) -> Void
    ) {
        let mutationDate = mutationDate ?? dependencies.now()
        var nextProfile = profile
        mutate(&nextProfile, mutationDate)
        nextProfile.updatedAt = mutationDate
        nextProfile.lastWriterDeviceId = dependencies.writerID
        applyProfile(nextProfile, scheduleCloudSync: scheduleCloudSync)
    }

    private func applyProfile(_ nextProfile: TerminalAccessoryProfile, scheduleCloudSync: Bool) {
        let normalizedProfile = nextProfile.normalized()
        guard normalizedProfile != profile else { return }

        profile = normalizedProfile
        persistProfile()
        publishProfileChange()

        if scheduleCloudSync {
            scheduleSyncWithCloud()
        }
    }

    private func publishProfileChange() {
        dependencies.publishProfileChange(self, profile)
    }

    private func persistProfile() {
        do {
            let encoded = try JSONEncoder().encode(profile)
            defaults.set(encoded, forKey: dependencies.persistenceKey)
        } catch {
            logger.error("Failed to encode terminal accessory profile: \(error.localizedDescription)")
        }
    }

    private static func loadProfile(
        from defaults: UserDefaults,
        key: String,
        writerID: String
    ) -> TerminalAccessoryProfile {
        guard let data = defaults.data(forKey: key) else {
            let defaultProfile = TerminalAccessoryProfile
                .defaultValue(lastWriterDeviceId: writerID)
                .normalized()
            if let encoded = try? JSONEncoder().encode(defaultProfile) {
                defaults.set(encoded, forKey: key)
            }
            return defaultProfile
        }

        do {
            var decoded = try JSONDecoder().decode(TerminalAccessoryProfile.self, from: data)
            if decoded.lastWriterDeviceId.isEmpty {
                decoded.lastWriterDeviceId = writerID
            }
            let normalized = decoded.normalized()
            if normalized != decoded, let encoded = try? JSONEncoder().encode(normalized) {
                defaults.set(encoded, forKey: key)
            }
            return normalized
        } catch {
            let defaultProfile = TerminalAccessoryProfile
                .defaultValue(lastWriterDeviceId: writerID)
                .normalized()
            if let encoded = try? JSONEncoder().encode(defaultProfile) {
                defaults.set(encoded, forKey: key)
            }
            return defaultProfile
        }
    }

    private func scheduleSyncWithCloud() {
        pendingSyncTask?.cancel()
        let waitForSyncDebounce = dependencies.waitForSyncDebounce
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        pendingSyncTask = Task { [weak self, waitForSyncDebounce, isSyncEnabled, mutationQueue] in
            try? await waitForSyncDebounce()
            guard !Task.isCancelled else { return }
            guard isSyncEnabled(), let profile = self?.profile else { return }
            mutationQueue.enqueueTerminalAccessoryProfileUpsert(profile)
            guard !Task.isCancelled, isSyncEnabled() else { return }
            await mutationQueue.drainPendingMutations()
        }
    }

    private func makeCloudSyncTask() -> Task<Void, Never> {
        let localSnapshot = profile
        let cloud = dependencies.cloud
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        let logger = logger

        return Task { [weak self, cloud, isSyncEnabled, mutationQueue, logger, localSnapshot] in
            guard !Task.isCancelled, isSyncEnabled() else { return }
            do {
                let cloudResolved = try await cloud.syncTerminalAccessoryProfile(localSnapshot)
                guard !Task.isCancelled, isSyncEnabled() else { return }
                self?.applyCloudResolution(cloudResolved)
                guard !Task.isCancelled, isSyncEnabled() else { return }
                await mutationQueue.drainPendingMutations()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isSyncEnabled() else { return }
                logger.warning("Terminal accessory CloudKit sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyCloudResolution(_ cloudResolved: TerminalAccessoryProfile) {
        let mergedWithCurrent = TerminalAccessoryProfile
            .merged(local: profile, remote: cloudResolved)
            .normalized()
        applyProfile(mergedWithCurrent, scheduleCloudSync: false)
    }

    private func observeSyncEvents(cleanup: TerminalAccessoryObserverCleanup) {
        let lifecycleObserverID = dependencies.syncLifecycle.observe { [weak self] event in
            self?.handleSyncLifecycleEvent(event)
        }
        cleanup.registerLifecycleObserver(lifecycleObserverID)
        let resolutionObserverID = dependencies.resolutionSource.observeTerminalAccessoryProfile { [weak self] resolvedProfile in
            guard let self else { return }
            let mergedWithCurrent = TerminalAccessoryProfile
                .merged(local: self.profile, remote: resolvedProfile)
                .normalized()
            self.applyProfile(mergedWithCurrent, scheduleCloudSync: false)
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
