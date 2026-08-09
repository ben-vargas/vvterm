//
//  TerminalThemeManager.swift
//  VVTerm
//

import Foundation
import Combine
import os.log

nonisolated struct TerminalThemeObserverCleanupRequest: Sendable {
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
private final class TerminalThemeObserverCleanup {
    private let preferenceChanges: any TerminalThemePreferenceChangeSource
    private let syncLifecycle: any TerminalThemeSyncLifecycle
    private var preferenceObserver: NSObjectProtocol?
    private var lifecycleObserverID: UUID?

    init(
        preferenceChanges: any TerminalThemePreferenceChangeSource,
        syncLifecycle: any TerminalThemeSyncLifecycle
    ) {
        self.preferenceChanges = preferenceChanges
        self.syncLifecycle = syncLifecycle
    }

    var request: TerminalThemeObserverCleanupRequest {
        TerminalThemeObserverCleanupRequest { [self] in
            removeObservers()
        }
    }

    func registerPreferenceObserver(_ observer: NSObjectProtocol) {
        preferenceObserver = observer
    }

    func registerLifecycleObserver(_ id: UUID) {
        lifecycleObserverID = id
    }

    private func removeObservers() {
        if let preferenceObserver {
            preferenceChanges.removeObserver(preferenceObserver)
            self.preferenceObserver = nil
        }
        if let lifecycleObserverID {
            syncLifecycle.removeObserver(lifecycleObserverID)
            self.lifecycleObserverID = nil
        }
    }
}

@MainActor
final class TerminalThemeManager: ObservableObject {
    @Published private(set) var customThemes: [TerminalTheme] = []
    @Published private(set) var themeSelection: TerminalThemeSelection
    @Published private(set) var activeAppearanceSnapshot: TerminalAppearanceSnapshot = .fallback

    private let dependencies: TerminalThemeManagerDependencies
    private let observerCleanupRequest: TerminalThemeObserverCleanupRequest
    private let logger = Logger(subsystem: "app.vivy.vvterm", category: "TerminalThemeManager")

    private var lastKnownPreferenceSnapshot: TerminalThemeSelection
    private var isApplyingRemotePreference = false
    private var pendingPreferenceSyncTask: Task<Void, Never>?
    private var startupSyncTask: Task<Void, Never>?
    private var lifecycleSyncTask: Task<Void, Never>?

    private var persistence: any TerminalThemePersistence { dependencies.persistence }

    init(dependencies: TerminalThemeManagerDependencies) {
        self.dependencies = dependencies
        let observerCleanup = TerminalThemeObserverCleanup(
            preferenceChanges: dependencies.preferenceChanges,
            syncLifecycle: dependencies.syncLifecycle
        )
        self.observerCleanupRequest = observerCleanup.request
        let initialSelection = dependencies.persistence.loadSelection()
        self.themeSelection = initialSelection
        self.lastKnownPreferenceSnapshot = initialSelection

        loadThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
        guard dependencies.startsSynchronization else { return }

        observeThemePreferenceChanges(cleanup: observerCleanup)
        observeSyncLifecycle(cleanup: observerCleanup)
        startupSyncTask = makeCloudSyncTask()
    }

    deinit {
        pendingPreferenceSyncTask?.cancel()
        startupSyncTask?.cancel()
        lifecycleSyncTask?.cancel()
        observerCleanupRequest.perform()
    }

    var customThemeNames: [String] {
        customThemes
            .filter { !$0.isDeleted && $0.canApply }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var builtInThemeNames: [String] {
        dependencies.builtInThemeCatalog.themeNames()
    }

    func applicationThemeName(preferred: String, fallback: String) -> String {
        guard let customTheme = customThemes.first(where: {
            !$0.isDeleted && $0.name == preferred
        }) else {
            return preferred
        }
        return customTheme.canApply ? preferred : fallback
    }

    func appearanceSnapshot(
        for activeAppearance: TerminalColorAppearance
    ) -> TerminalAppearanceSnapshot {
        let darkTheme = resolvedTheme(
            preferred: themeSelection.darkThemeName,
            fallback: "Aizen Dark"
        )
        let lightTheme = themeSelection.usePerAppearanceTheme
            ? resolvedTheme(
                preferred: themeSelection.lightThemeName,
                fallback: "Aizen Light"
            )
            : darkTheme

        return TerminalAppearanceSnapshot(
            activeAppearance: activeAppearance,
            lightTheme: lightTheme,
            darkTheme: darkTheme
        )
    }

    @discardableResult
    func activateAppearance(
        _ appearance: TerminalColorAppearance
    ) -> TerminalAppearanceSnapshot {
        let snapshot = appearanceSnapshot(for: appearance)
        if activeAppearanceSnapshot != snapshot {
            activeAppearanceSnapshot = snapshot
        }

        let backgroundHex = snapshot.activeTheme.palette.backgroundHex
        persistence.cacheActiveBackgroundHex(backgroundHex)
        return snapshot
    }

    func suggestThemeName(from sourceName: String?) -> String {
        let trimmed = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return uniqueThemeName(from: "Custom Theme")
        }
        let sanitized = sanitizeThemeName(trimmed)
        return uniqueThemeName(from: sanitized.isEmpty ? "Custom Theme" : sanitized)
    }

    func createCustomTheme(name: String, content: String) throws -> TerminalTheme {
        let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalThemeValidationError.invalidName }
        let sanitized = sanitizeThemeName(trimmed)
        guard !sanitized.isEmpty else { throw TerminalThemeValidationError.invalidName }
        let finalName = try TerminalThemeValidator.validateAndNormalizeThemeName(
            uniqueThemeName(from: sanitized)
        )

        let theme = TerminalTheme(
            name: finalName,
            content: normalizedContent,
            updatedAt: dependencies.now(),
            deletedAt: nil
        )

        customThemes.append(theme)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
        pushThemeToCloud(theme)
        return theme
    }

    @discardableResult
    func updateCustomTheme(id: UUID, name: String, content: String) throws -> TerminalTheme {
        guard let index = customThemes.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TerminalThemeValidationError.themeNotFound
        }

        let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalThemeValidationError.invalidName }

        let sanitized = sanitizeThemeName(trimmed)
        guard !sanitized.isEmpty else { throw TerminalThemeValidationError.invalidName }

        let previousName = customThemes[index].name
        let finalName = try TerminalThemeValidator.validateAndNormalizeThemeName(
            uniqueThemeName(from: sanitized, excludingThemeID: id)
        )
        let now = dependencies.now()

        customThemes[index].name = finalName
        customThemes[index].content = normalizedContent
        customThemes[index].updatedAt = now
        customThemes[index].deletedAt = nil

        migrateSelectionsForRenamedTheme(from: previousName, to: finalName)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
        pushThemeToCloud(customThemes[index])

        return customThemes[index]
    }

    func deleteCustomTheme(named name: String) {
        guard let index = customThemes.firstIndex(where: { $0.name == name && !$0.isDeleted }) else {
            return
        }

        deleteTheme(at: index)
    }

    func deleteCustomTheme(id: UUID) {
        guard let index = customThemes.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }

        deleteTheme(at: index)
    }

    private func deleteTheme(at index: Int) {
        let now = dependencies.now()
        customThemes[index].deletedAt = now
        customThemes[index].updatedAt = now
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
        pushThemeToCloud(customThemes[index])
    }

    private func loadThemes() {
        do {
            customThemes = try persistence.loadCustomThemes()
        } catch {
            customThemes = []
            logger.error("Failed to load custom themes: \(error.localizedDescription)")
        }
    }

    private func saveThemes() {
        do {
            try persistence.saveCustomThemes(customThemes)
        } catch {
            logger.error("Failed to save custom themes: \(error.localizedDescription)")
        }
    }

    private func syncCustomThemeFiles() {
        defer { dependencies.paletteResolver.invalidateCache() }

        do {
            try dependencies.themeFiles.synchronize(customThemes)
        } catch {
            logger.error("Failed to sync custom theme files: \(error.localizedDescription)")
        }
    }

    private func ensureThemeSelectionIsValid() {
        let storedThemeNames = customThemes.filter { !$0.isDeleted }.map(\.name)
        let available = Set(dependencies.builtInThemeCatalog.themeNames() + storedThemeNames)
        let fallbackDark = "Aizen Dark"
        let fallbackLight = "Aizen Light"

        let selection = currentPreferenceSnapshot()
        let correctedSelection = TerminalThemeSelection(
            darkThemeName: available.contains(selection.darkThemeName)
                ? selection.darkThemeName
                : fallbackDark,
            lightThemeName: available.contains(selection.lightThemeName)
                ? selection.lightThemeName
                : fallbackLight,
            usePerAppearanceTheme: selection.usePerAppearanceTheme
        )

        if correctedSelection != selection {
            persistence.saveSelection(correctedSelection)
            lastKnownPreferenceSnapshot = correctedSelection
        }
    }

    private func sanitizeThemeName(_ name: String) -> String {
        var sanitized = name.replacingOccurrences(of: "/", with: "-")
        sanitized = sanitized.replacingOccurrences(of: "\\", with: "-")
        sanitized = sanitized.replacingOccurrences(of: ":", with: "-")
        sanitized = String(sanitized.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        })
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "." || trimmed == ".." ? "" : trimmed
    }

    private func uniqueThemeName(from baseName: String, excludingThemeID: UUID? = nil) -> String {
        let builtIn = Set(
            dependencies.builtInThemeCatalog.themeNames().map(normalizedThemeNameKey(_:))
        )
        let existing = Set(
            customThemes
                .filter { !$0.isDeleted && $0.id != excludingThemeID }
                .map { normalizedThemeNameKey($0.name) }
        )
        let maxLength = 80

        var root = String(baseName.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        if root.isEmpty { root = "Custom Theme" }

        if !builtIn.contains(normalizedThemeNameKey(root)) &&
            !existing.contains(normalizedThemeNameKey(root)) {
            return root
        }

        var index = 2
        while true {
            let suffix = " \(index)"
            let availableRootLength = max(1, maxLength - suffix.count)
            let candidateRoot = String(root.prefix(availableRootLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = "\(candidateRoot)\(suffix)"
            if !builtIn.contains(normalizedThemeNameKey(candidate)) &&
                !existing.contains(normalizedThemeNameKey(candidate)) {
                return candidate
            }
            index += 1
        }
    }

    private func normalizedThemeNameKey(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func migrateSelectionsForRenamedTheme(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        let selection = currentPreferenceSnapshot()
        let migratedSelection = TerminalThemeSelection(
            darkThemeName: selection.darkThemeName == oldName
                ? newName
                : selection.darkThemeName,
            lightThemeName: selection.lightThemeName == oldName
                ? newName
                : selection.lightThemeName,
            usePerAppearanceTheme: selection.usePerAppearanceTheme
        )
        guard migratedSelection != selection else { return }
        persistence.saveSelection(migratedSelection)
    }

    private func observeThemePreferenceChanges(cleanup: TerminalThemeObserverCleanup) {
        let observer = dependencies.preferenceChanges.observeChanges { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleThemePreferenceChange()
            }
        }
        cleanup.registerPreferenceObserver(observer)
    }

    private func observeSyncLifecycle(cleanup: TerminalThemeObserverCleanup) {
        let observerID = dependencies.syncLifecycle.observe { [weak self] event in
            self?.handleSyncLifecycleEvent(event)
        }
        cleanup.registerLifecycleObserver(observerID)
    }

    private func handleThemePreferenceChange() {
        guard !isApplyingRemotePreference else { return }
        let snapshot = currentPreferenceSnapshot()
        guard snapshot != lastKnownPreferenceSnapshot else { return }
        lastKnownPreferenceSnapshot = snapshot
        refreshActiveAppearance()

        let now = dependencies.now()
        persistence.savePreferenceUpdatedAt(now)
        schedulePreferenceCloudSync(
            TerminalThemePreference(
                darkThemeName: snapshot.darkThemeName,
                lightThemeName: snapshot.lightThemeName,
                usePerAppearanceTheme: snapshot.usePerAppearanceTheme,
                updatedAt: now
            )
        )
    }

    private func currentPreferenceSnapshot() -> TerminalThemeSelection {
        persistence.loadSelection()
    }

    private func localPreferenceUpdatedAt() -> Date {
        persistence.loadPreferenceUpdatedAt()
    }

    private func schedulePreferenceCloudSync(_ preference: TerminalThemePreference) {
        pendingPreferenceSyncTask?.cancel()
        let waitForPreferenceSyncDebounce = dependencies.waitForPreferenceSyncDebounce
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        pendingPreferenceSyncTask = Task { [waitForPreferenceSyncDebounce, isSyncEnabled, mutationQueue, preference] in
            try? await waitForPreferenceSyncDebounce()
            guard !Task.isCancelled else { return }
            guard !Task.isCancelled, isSyncEnabled() else { return }
            mutationQueue.enqueueTerminalThemePreferenceUpsert(preference)
            guard !Task.isCancelled, isSyncEnabled() else { return }
            await mutationQueue.drainPendingMutations()
        }
    }

    private func pushThemeToCloud(_ theme: TerminalTheme) {
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        Task { @MainActor [isSyncEnabled, mutationQueue, theme] in
            guard isSyncEnabled() else { return }
            mutationQueue.enqueueTerminalThemeUpsert(theme)
            guard !Task.isCancelled, isSyncEnabled() else { return }
            await mutationQueue.drainPendingMutations()
        }
    }

    private func makeCloudSyncTask() -> Task<Void, Never> {
        let localThemesSnapshot = customThemes
        let cloud = dependencies.cloud
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        let logger = logger

        return Task { [weak self, cloud, isSyncEnabled, mutationQueue, logger, localThemesSnapshot] in
            guard !Task.isCancelled, isSyncEnabled() else { return }
            do {
                let remoteThemes = try await cloud.fetchTerminalThemes()
                guard !Task.isCancelled, isSyncEnabled() else { return }
                if let manager = self {
                    manager.applyRemoteThemesAndEnqueueMissing(
                        remoteThemes,
                        localThemesSnapshot: localThemesSnapshot,
                        mutationQueue: mutationQueue
                    )
                } else {
                    return
                }

                guard !Task.isCancelled, isSyncEnabled() else { return }
                let remotePreference = try await cloud.fetchTerminalThemePreference()
                guard !Task.isCancelled, isSyncEnabled() else { return }
                if let manager = self {
                    manager.applyRemotePreferenceOrEnqueueLocal(
                        remotePreference,
                        mutationQueue: mutationQueue
                    )
                } else {
                    return
                }

                guard !Task.isCancelled, isSyncEnabled() else { return }
                await mutationQueue.drainPendingMutations()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isSyncEnabled() else { return }
                logger.warning("Custom theme CloudKit sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyRemoteThemesAndEnqueueMissing(
        _ remoteThemes: [TerminalTheme],
        localThemesSnapshot: [TerminalTheme],
        mutationQueue: any TerminalThemeMutationQueue
    ) {
        var remoteByID: [UUID: TerminalTheme] = [:]
        for remoteTheme in remoteThemes {
            guard let validTheme = try? TerminalThemeValidator.validateStoredTheme(remoteTheme) else {
                continue
            }
            if let existing = remoteByID[validTheme.id],
               existing.updatedAt >= validTheme.updatedAt {
                continue
            }
            remoteByID[validTheme.id] = validTheme
        }

        mergeRemoteThemes(remoteThemes)

        for localTheme in localThemesSnapshot {
            if let remoteTheme = remoteByID[localTheme.id],
               remoteTheme.updatedAt >= localTheme.updatedAt {
                continue
            }
            mutationQueue.enqueueTerminalThemeUpsert(localTheme)
        }
    }

    private func applyRemotePreferenceOrEnqueueLocal(
        _ remotePreference: TerminalThemePreference?,
        mutationQueue: any TerminalThemeMutationQueue
    ) {
        if let remotePreference {
            applyRemotePreferenceIfNewer(remotePreference)
            return
        }

        let localUpdatedAt = localPreferenceUpdatedAt()
        let seedUpdatedAt: Date
        if localUpdatedAt == .distantPast {
            seedUpdatedAt = dependencies.now()
            persistence.savePreferenceUpdatedAt(seedUpdatedAt)
        } else {
            seedUpdatedAt = localUpdatedAt
        }

        let selection = currentPreferenceSnapshot()
        mutationQueue.enqueueTerminalThemePreferenceUpsert(
            TerminalThemePreference(
                darkThemeName: selection.darkThemeName,
                lightThemeName: selection.lightThemeName,
                usePerAppearanceTheme: selection.usePerAppearanceTheme,
                updatedAt: seedUpdatedAt
            )
        )
    }

    private func handleSyncLifecycleEvent(_ event: CloudKitSyncLifecycleEvent) {
        switch event {
        case .foreground, .syncEnabled:
            startupSyncTask?.cancel()
            startupSyncTask = nil
            lifecycleSyncTask?.cancel()
            lifecycleSyncTask = makeCloudSyncTask()
        case .syncDisabled:
            pendingPreferenceSyncTask?.cancel()
            pendingPreferenceSyncTask = nil
            startupSyncTask?.cancel()
            startupSyncTask = nil
            lifecycleSyncTask?.cancel()
            lifecycleSyncTask = nil
        }
    }

    private func mergeRemoteThemes(_ remoteThemes: [TerminalTheme]) {
        customThemes = TerminalThemeMergePolicy.merge(local: customThemes, remote: remoteThemes)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
    }

    private func applyRemotePreferenceIfNewer(_ preference: TerminalThemePreference) {
        let localUpdatedAt = localPreferenceUpdatedAt()
        guard preference.updatedAt > localUpdatedAt else { return }

        isApplyingRemotePreference = true
        persistence.saveSelection(
            TerminalThemeSelection(
                darkThemeName: preference.darkThemeName,
                lightThemeName: preference.lightThemeName,
                usePerAppearanceTheme: preference.usePerAppearanceTheme
            )
        )
        persistence.savePreferenceUpdatedAt(preference.updatedAt)
        isApplyingRemotePreference = false

        ensureThemeSelectionIsValid()
        lastKnownPreferenceSnapshot = currentPreferenceSnapshot()
        refreshActiveAppearance()
    }

    private func resolvedTheme(
        preferred: String,
        fallback: String
    ) -> ResolvedTerminalTheme {
        let name = applicationThemeName(preferred: preferred, fallback: fallback)
        let palette: TerminalThemePalette
        if let customTheme = customThemes.first(where: {
            !$0.isDeleted && $0.canApply && $0.name == name
        }) {
            palette = dependencies.paletteResolver.palette(
                forThemeContent: customTheme.content
            )
        } else {
            palette = dependencies.paletteResolver.palette(forThemeNamed: name)
        }
        return ResolvedTerminalTheme(
            name: name,
            palette: palette
        )
    }

    private func refreshActiveAppearance() {
        let selection = currentPreferenceSnapshot()
        if themeSelection != selection {
            themeSelection = selection
        }
        _ = activateAppearance(activeAppearanceSnapshot.activeAppearance)
    }
}
