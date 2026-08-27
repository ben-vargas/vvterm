import Combine
import Foundation
import os.log

@MainActor
final class TerminalFontStore: ObservableObject {
    @Published private(set) var fontRecords: [TerminalFont]
    @Published private(set) var catalog = TerminalFontCatalog.empty
    @Published private(set) var preference: TerminalFontPreference
    @Published private var registeredFamiliesByFontID: [
        TerminalFont.ID: [TerminalFontFamily]
    ] = [:]

    let dependencies: TerminalFontStoreDependencies
    let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "TerminalFontStore"
    )
    var lifecycleObserverID: UUID?
    var syncTask: Task<Void, Never>?

    init(dependencies: TerminalFontStoreDependencies) {
        self.dependencies = dependencies
        fontRecords = []
        let storedPreference = dependencies.repository.loadPreference()
        preference = (try? TerminalFontValidator.validatePreference(storedPreference))
            ?? .defaultValue
        if preference != storedPreference {
            dependencies.repository.savePreference(preference)
        }
        let storedFonts: [TerminalFont]
        do {
            storedFonts = try dependencies.repository.loadFonts()
        } catch {
            storedFonts = []
            logger.error("Failed to load custom fonts: \(error.localizedDescription)")
        }
        fontRecords = TerminalFontMergePolicy.normalized(storedFonts)

        if fontRecords != storedFonts {
            saveFonts()
        }
        reloadLibrary()
        startSynchronizationIfNeeded()
    }

    isolated deinit {
        syncTask?.cancel()
        if let lifecycleObserverID {
            dependencies.syncLifecycle.removeObserver(lifecycleObserverID)
        }
    }

    var customFonts: [TerminalFont] {
        fontRecords.filter { !$0.isDeleted }
    }

    func isAvailable(_ font: TerminalFont) -> Bool {
        registeredFamiliesByFontID[font.id] != nil
    }

    @discardableResult
    func importFont(
        from sourceURL: URL,
        allowsProFeatures: Bool
    ) throws -> TerminalFont {
        guard allowsProFeatures else { throw TerminalFontValidationError.requiresPro }

        let imported = try dependencies.repository.importFont(
            from: sourceURL,
            now: dependencies.now()
        )
        var updatedRecords = fontRecords.filter { $0.id != imported.id }
        updatedRecords.append(imported)
        fontRecords = TerminalFontMergePolicy.normalized(updatedRecords)
        saveFonts()
        reloadLibrary()
        enqueueFont(imported)
        return imported
    }

    func deleteFont(id: TerminalFont.ID) {
        guard let index = fontRecords.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }

        let now = dependencies.now()
        var deletedFont = fontRecords[index]
        deletedFont.updatedAt = now
        deletedFont.deletedAt = now
        fontRecords[index] = deletedFont
        saveFonts()
        dependencies.repository.removeFile(for: deletedFont)
        reloadLibrary()
        clearSelections(providedBy: [deletedFont])
        enqueueFont(deletedFont)
    }

    func selectPrimaryFamily(
        _ familyName: String,
        allowsProFeatures: Bool
    ) throws {
        let name = normalizedFamilyName(familyName)
        guard catalog.family(named: name) != nil else {
            throw TerminalFontValidationError.fileUnavailable
        }
        guard allowsProFeatures
                || !TerminalFontSelectionPolicy.requiresProForPrimarySelection(
                    name,
                    catalog: catalog
                ) else {
            throw TerminalFontValidationError.requiresPro
        }

        saveSelection(primaryFamily: name, cjkFamily: preference.cjkFamily)
    }

    func selectCJKFamily(
        _ familyName: String?,
        allowsProFeatures: Bool
    ) throws {
        let name = familyName
            .map(normalizedFamilyName)
            .flatMap { $0.isEmpty ? nil : $0 }
        if let name {
            guard allowsProFeatures else { throw TerminalFontValidationError.requiresPro }
            guard catalog.family(named: name) != nil else {
                throw TerminalFontValidationError.fileUnavailable
            }
        }

        saveSelection(primaryFamily: preference.primaryFamily, cjkFamily: name)
    }

    func refreshCatalog() {
        let updated = dependencies.loadCatalog(
            registeredFamiliesByFontID.values.flatMap { $0 }
        )
        guard updated != catalog else { return }
        catalog = updated
    }

    func refreshFromCloud() async throws {
        syncTask?.cancel()
        syncTask = nil
        try await synchronizeWithCloud()
    }

    private func reloadLibrary() {
        registeredFamiliesByFontID = dependencies.repository.registerAvailableFonts(fontRecords)
        refreshCatalog()
    }

    private func saveFonts() {
        do {
            try dependencies.repository.saveFonts(fontRecords)
        } catch {
            logger.error("Failed to save custom fonts: \(error.localizedDescription)")
        }
    }

    func mergeRemoteFonts(_ remoteFonts: [TerminalFont]) {
        fontRecords = TerminalFontMergePolicy.merge(
            local: fontRecords,
            remote: remoteFonts
        )
        saveFonts()
        reloadLibrary()
    }

    private func saveSelection(primaryFamily: String, cjkFamily: String?) {
        let updated = TerminalFontPreference(
            primaryFamily: primaryFamily,
            cjkFamily: cjkFamily,
            updatedAt: dependencies.now()
        )
        guard updated.primaryFamily != preference.primaryFamily
                || updated.cjkFamily != preference.cjkFamily else {
            return
        }

        applyPreference(updated, enqueueForSync: true)
    }

    func clearSelections(providedBy fonts: [TerminalFont]) {
        let families = Set(fonts.flatMap(\.familyNames))
        guard !families.isEmpty else { return }
        var primary = preference.primaryFamily
        var cjk = preference.cjkFamily

        if families.contains(primary), catalog.family(named: primary) == nil {
            primary = TerminalDefaults.defaultFontName
        }
        if let cjkName = cjk,
           families.contains(cjkName),
           catalog.family(named: cjkName) == nil {
            cjk = nil
        }
        saveSelection(primaryFamily: primary, cjkFamily: cjk)
    }

    func applyPreference(
        _ updated: TerminalFontPreference,
        enqueueForSync: Bool
    ) {
        guard updated != preference else { return }
        preference = updated
        dependencies.repository.savePreference(updated)
        if enqueueForSync {
            enqueuePreference(updated)
        }
    }

    private func normalizedFamilyName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
