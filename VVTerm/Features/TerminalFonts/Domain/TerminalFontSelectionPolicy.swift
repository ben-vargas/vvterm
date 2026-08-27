import Foundation

nonisolated enum TerminalFontSelectionPolicy {
    static func resolve(
        primaryFamily: String,
        cjkFamily: String,
        catalog: TerminalFontCatalog,
        allowsProFeatures: Bool
    ) -> TerminalFontRuntimeSelection {
        let resolvedPrimary = resolvedPrimaryFamily(
            primaryFamily,
            catalog: catalog,
            allowsProFeatures: allowsProFeatures
        )
        let resolvedCJK = resolvedCJKFamily(
            cjkFamily,
            catalog: catalog,
            allowsProFeatures: allowsProFeatures
        )

        return TerminalFontRuntimeSelection(
            primaryFamily: resolvedPrimary,
            cjkFamily: resolvedCJK
        )
    }

    static func primarySelectionRequiresPro(
        _ familyName: String,
        catalog: TerminalFontCatalog
    ) -> Bool {
        let normalizedName = normalized(familyName)
        guard normalizedName != TerminalDefaults.defaultFontName else { return false }
        guard !TerminalDefaults.bundledFontFamilyNames.contains(normalizedName) else {
            return false
        }
        guard let family = catalog.family(named: normalizedName) else { return true }
        return family.source == .custom
    }

    private static func resolvedPrimaryFamily(
        _ familyName: String,
        catalog: TerminalFontCatalog,
        allowsProFeatures: Bool
    ) -> String {
        let normalizedName = normalized(familyName)
        guard !normalizedName.isEmpty else { return TerminalDefaults.defaultFontName }
        guard normalizedName != TerminalDefaults.defaultFontName else { return normalizedName }
        guard let family = catalog.family(named: normalizedName) else {
            return TerminalDefaults.defaultFontName
        }
        guard family.source != .custom || allowsProFeatures else {
            return TerminalDefaults.defaultFontName
        }
        return family.name
    }

    private static func resolvedCJKFamily(
        _ familyName: String,
        catalog: TerminalFontCatalog,
        allowsProFeatures: Bool
    ) -> String? {
        let normalizedName = normalized(familyName)
        guard !normalizedName.isEmpty, allowsProFeatures else { return nil }
        return catalog.family(named: normalizedName)?.name
    }

    private static func normalized(_ family: String) -> String {
        family.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
