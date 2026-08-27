import Testing
@testable import VVTerm

struct TerminalFontCatalogTests {
    @Test
    func catalogNormalizesDeduplicatesAndSortsFamilies() {
        let catalog = TerminalFontCatalog(families: [
            family(" Zebra ", source: .system),
            family("Alpha", source: .system),
            family("Zebra", source: .custom),
            family(" ", source: .builtIn)
        ])

        #expect(catalog.families.map(\.name) == ["Alpha", "Zebra"])
        #expect(catalog.family(named: " Zebra ")?.source == .custom)
    }

    @Test
    func availableFamiliesIncludeEveryFont() {
        let catalog = TerminalFontCatalog(families: [
            family("System Proportional", source: .system),
            family("System Mono", source: .system),
            family("Custom Proportional", source: .custom),
            family("Built-in", source: .builtIn)
        ])

        #expect(catalog.availableFamilies(ensuring: "").map(\.name) == [
            "Built-in",
            "Custom Proportional",
            "System Mono",
            "System Proportional"
        ])
    }

    @Test
    func sourceOrderIsBuiltInCustomThenSystem() {
        #expect(TerminalFontFamily.Source.allCases == [
            .builtIn,
            .custom,
            .system
        ])
    }

    @Test
    func unavailableStoredFamilyRemainsVisibleWithoutChangingCatalog() {
        let catalog = TerminalFontCatalog(families: [family("Menlo", source: .system)])

        let visible = catalog.availableFamilies(ensuring: " User Font ")

        #expect(visible.map(\.name) == ["Menlo", "User Font"])
        #expect(visible.last?.source == .custom)
        #expect(catalog.family(named: "User Font") == nil)
    }

    private func family(
        _ name: String,
        source: TerminalFontFamily.Source
    ) -> TerminalFontFamily {
        TerminalFontFamily(
            name: name,
            source: source
        )
    }
}
