import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum TerminalAccessoryValidationError: LocalizedError {
    case customActionLimitReached
    case emptyTitle
    case emptyCommandContent
    case customActionNotFound

    var errorDescription: String? {
        switch self {
        case .customActionLimitReached:
            return String(
                format: String(localized: "You can create up to %lld custom actions."),
                Int64(TerminalAccessoryProfile.maxCustomActions)
            )
        case .emptyTitle:
            return String(localized: "Action title cannot be empty.")
        case .emptyCommandContent:
            return String(localized: "Command content cannot be empty.")
        case .customActionNotFound:
            return String(localized: "Action not found.")
        }
    }
}

extension Notification.Name {
    static let terminalAccessoryProfileDidChange = Notification.Name("TerminalAccessoryProfileDidChange")
}

@MainActor
final class TerminalAccessoryPreferencesManager: ObservableObject {
    static let shared = TerminalAccessoryPreferencesManager()

    @Published private(set) var profile: TerminalAccessoryProfile

    private let defaults: UserDefaults
    private let cloudKit: CloudKitManager
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "TerminalAccessoryPreferences"
    )

    private var foregroundObserver: NSObjectProtocol?
    private var syncToggleObserver: NSObjectProtocol?
    private var pendingSyncTask: Task<Void, Never>?
    private var lastKnownSyncEnabled: Bool

    init(defaults: UserDefaults = .standard, cloudKit: CloudKitManager? = nil) {
        self.defaults = defaults
        self.cloudKit = cloudKit ?? CloudKitManager.shared
        self.profile = TerminalAccessoryPreferencesManager.loadProfile(from: defaults)
        self.lastKnownSyncEnabled = SyncSettings.isEnabled

        observeForegroundSync()
        observeSyncToggleChanges()

        Task {
            await syncWithCloud()
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let syncToggleObserver {
            NotificationCenter.default.removeObserver(syncToggleObserver)
        }
        pendingSyncTask?.cancel()
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

    func customAction(for id: UUID) -> TerminalAccessoryCustomAction? {
        customActions.first { $0.id == id }
    }

    func createCustomAction(
        title: String,
        kind: TerminalAccessoryCustomActionKind,
        commandContent: String,
        commandSendMode: TerminalSnippetSendMode,
        shortcutKey: TerminalAccessoryShortcutKey,
        shortcutModifiers: TerminalAccessoryShortcutModifiers
    ) throws -> TerminalAccessoryCustomAction {
        guard canCreateCustomAction else {
            throw TerminalAccessoryValidationError.customActionLimitReached
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommandContent = commandContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TerminalAccessoryValidationError.emptyTitle
        }
        if kind == .command && trimmedCommandContent.isEmpty {
            throw TerminalAccessoryValidationError.emptyCommandContent
        }

        let now = Date()
        let action = TerminalAccessoryCustomAction(
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

        var nextProfile = profile
        nextProfile.customActions.insert(action, at: 0)
        nextProfile.updatedAt = now
        nextProfile.lastWriterDeviceId = DeviceIdentity.id
        applyProfile(nextProfile, scheduleCloudSync: true)
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

        let now = Date()
        var nextProfile = profile
        nextProfile.customActions[index].title = String(trimmedTitle.prefix(TerminalAccessoryProfile.maxCustomActionTitleLength))
        nextProfile.customActions[index].kind = kind
        nextProfile.customActions[index].commandContent = kind == .command
            ? String(commandContent.prefix(TerminalAccessoryProfile.maxCommandContentLength))
            : ""
        nextProfile.customActions[index].commandSendMode = commandSendMode
        nextProfile.customActions[index].shortcutKey = shortcutKey
        nextProfile.customActions[index].shortcutModifiers = shortcutModifiers
        nextProfile.customActions[index].updatedAt = now
        nextProfile.customActions[index].deletedAt = nil
        nextProfile.updatedAt = now
        nextProfile.lastWriterDeviceId = DeviceIdentity.id
        applyProfile(nextProfile, scheduleCloudSync: true)
        return nextProfile.customActions[index]
    }

    func deleteCustomAction(id: UUID) {
        guard let index = profile.customActions.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }

        let now = Date()
        var nextProfile = profile
        nextProfile.customActions[index].title = ""
        nextProfile.customActions[index].commandContent = ""
        nextProfile.customActions[index].deletedAt = now
        nextProfile.customActions[index].updatedAt = now
        nextProfile.updatedAt = now
        nextProfile.lastWriterDeviceId = DeviceIdentity.id
        applyProfile(nextProfile, scheduleCloudSync: true)
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
        let now = Date()
        var nextProfile = profile
        nextProfile.layout.activeItems = TerminalAccessoryProfile.defaultActiveItems
        nextProfile.layout.updatedAt = now
        nextProfile.updatedAt = now
        nextProfile.lastWriterDeviceId = DeviceIdentity.id
        applyProfile(nextProfile, scheduleCloudSync: true)
    }

    func refreshFromCloud() async {
        await syncWithCloud()
    }

    private func updateLayoutItems(_ items: [TerminalAccessoryItemRef]) {
        let now = Date()
        var nextProfile = profile
        nextProfile.layout.activeItems = items
        nextProfile.layout.updatedAt = now
        nextProfile.updatedAt = now
        nextProfile.lastWriterDeviceId = DeviceIdentity.id
        applyProfile(nextProfile, scheduleCloudSync: true)
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
        NotificationCenter.default.post(
            name: .terminalAccessoryProfileDidChange,
            object: self,
            userInfo: ["profile": profile]
        )
    }

    private func persistProfile() {
        do {
            let encoded = try JSONEncoder().encode(profile)
            defaults.set(encoded, forKey: TerminalAccessoryProfile.defaultsKey)
        } catch {
            logger.error("Failed to encode terminal accessory profile: \(error.localizedDescription)")
        }
    }

    private static func loadProfile(from defaults: UserDefaults) -> TerminalAccessoryProfile {
        guard let data = defaults.data(forKey: TerminalAccessoryProfile.defaultsKey) else {
            let defaultProfile = TerminalAccessoryProfile.defaultValue.normalized()
            if let encoded = try? JSONEncoder().encode(defaultProfile) {
                defaults.set(encoded, forKey: TerminalAccessoryProfile.defaultsKey)
            }
            return defaultProfile
        }

        do {
            let decoded = try JSONDecoder().decode(TerminalAccessoryProfile.self, from: data)
            let normalized = decoded.normalized()
            if normalized != decoded, let encoded = try? JSONEncoder().encode(normalized) {
                defaults.set(encoded, forKey: TerminalAccessoryProfile.defaultsKey)
            }
            return normalized
        } catch {
            let defaultProfile = TerminalAccessoryProfile.defaultValue.normalized()
            if let encoded = try? JSONEncoder().encode(defaultProfile) {
                defaults.set(encoded, forKey: TerminalAccessoryProfile.defaultsKey)
            }
            return defaultProfile
        }
    }

    private func scheduleSyncWithCloud() {
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncWithCloud()
        }
    }

    private func syncWithCloud() async {
        guard SyncSettings.isEnabled else { return }

        let localSnapshot = profile

        do {
            let cloudResolved = try await cloudKit.syncTerminalAccessoryProfile(localSnapshot)
            let mergedWithCurrent = TerminalAccessoryProfile.merged(local: profile, remote: cloudResolved).normalized()
            applyProfile(mergedWithCurrent, scheduleCloudSync: false)
        } catch {
            logger.warning("Terminal accessory CloudKit sync failed: \(error.localizedDescription)")
        }
    }

    private func observeForegroundSync() {
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #else
        return
        #endif

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncWithCloud()
            }
        }
    }

    private func observeSyncToggleChanges() {
        syncToggleObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isEnabled = SyncSettings.isEnabled
                guard isEnabled != self.lastKnownSyncEnabled else { return }
                self.lastKnownSyncEnabled = isEnabled
                if isEnabled {
                    await self.syncWithCloud()
                } else {
                    self.pendingSyncTask?.cancel()
                    self.pendingSyncTask = nil
                }
            }
        }
    }
}
