import Testing
@testable import VVTerm

struct TerminalFontCatalogTests {
    @Test
    func catalogNormalizesDeduplicatesAndSortsFamilies() {
        let catalog = TerminalFontCatalog(families: [
            family(" Zebra ", source: .system, isMonospaced: false),
            family("Alpha", source: .system),
            family("Zebra", source: .custom, isMonospaced: true),
            family(" ", source: .builtIn)
        ])

        #expect(catalog.families.map(\.name) == ["Alpha", "Zebra"])
        #expect(catalog.family(named: " Zebra ")?.source == .custom)
        #expect(catalog.family(named: "Zebra")?.isMonospaced == true)
    }

    @Test
    func primaryFamiliesIncludeMonospacedAndAppOwnedFonts() {
        let catalog = TerminalFontCatalog(families: [
            family("System Proportional", source: .system, isMonospaced: false),
            family("System Mono", source: .system),
            family("Custom Proportional", source: .custom, isMonospaced: false),
            family("Built-in", source: .builtIn, isMonospaced: false)
        ])

        #expect(catalog.primaryFamilies.map(\.name) == [
            "Built-in",
            "Custom Proportional",
            "System Mono"
        ])
    }

    @Test
    func unavailableStoredFamilyRemainsVisibleWithoutChangingCatalog() {
        let catalog = TerminalFontCatalog(families: [family("Menlo", source: .system)])

        let visible = catalog.primaryFamilies(ensuring: " User Font ")

        #expect(visible.map(\.name) == ["Menlo", "User Font"])
        #expect(visible.last?.source == .custom)
        #expect(catalog.family(named: "User Font") == nil)
    }

    private func family(
        _ name: String,
        source: TerminalFontFamily.Source,
        isMonospaced: Bool = true
    ) -> TerminalFontFamily {
        TerminalFontFamily(
            name: name,
            source: source,
            isMonospaced: isMonospaced
        )
    }
}
