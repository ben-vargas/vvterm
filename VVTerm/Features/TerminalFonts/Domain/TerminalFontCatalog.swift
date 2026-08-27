import Foundation

nonisolated struct TerminalFontCatalog: Equatable, Sendable {
    static let empty = TerminalFontCatalog(families: [])

    let families: [TerminalFontFamily]

    init(families: [TerminalFontFamily]) {
        var familiesByName: [String: TerminalFontFamily] = [:]

        for family in families {
            let name = family.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let normalized = TerminalFontFamily(
                name: name,
                source: family.source
            )

            if let existing = familiesByName[name] {
                familiesByName[name] = TerminalFontFamily(
                    name: name,
                    source: Self.mergedSource(existing.source, normalized.source)
                )
            } else {
                familiesByName[name] = normalized
            }
        }

        self.families = familiesByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func family(named name: String) -> TerminalFontFamily? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return families.first { $0.name == normalizedName }
    }

    func availableFamilies(ensuring currentName: String) -> [TerminalFontFamily] {
        let normalizedName = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return families }
        guard !families.contains(where: { $0.name == normalizedName }) else {
            return families
        }

        return (
            families + [
                TerminalFontFamily(
                    name: normalizedName,
                    source: .custom
                )
            ]
        ).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func mergedSource(
        _ first: TerminalFontFamily.Source,
        _ second: TerminalFontFamily.Source
    ) -> TerminalFontFamily.Source {
        if first == .builtIn || second == .builtIn {
            return .builtIn
        }
        if first == .custom || second == .custom {
            return .custom
        }
        return .system
    }
}
