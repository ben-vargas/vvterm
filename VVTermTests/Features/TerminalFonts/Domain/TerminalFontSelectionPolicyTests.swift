import Testing
@testable import VVTerm

struct TerminalFontSelectionPolicyTests {
    private let systemFamily = "Test System Mono"
    private let customFamily = "Test Custom Mono"
    private let cjkFamily = "Test CJK"

    @Test
    func proSelectionUsesCustomPrimaryAndCJKOverride() {
        let selection = TerminalFontSelectionPolicy.resolve(
            primaryFamily: customFamily,
            cjkFamily: cjkFamily,
            catalog: catalog,
            allowsProFeatures: true
        )

        #expect(selection.fontFamilies == expectedFamilies(
            primary: customFamily,
            cjk: cjkFamily
        ))
        #expect(selection.cjkFamily == cjkFamily)
    }

    @Test
    func freeSelectionKeepsSystemPrimaryButDoesNotUseCJKOverride() {
        let selection = TerminalFontSelectionPolicy.resolve(
            primaryFamily: systemFamily,
            cjkFamily: cjkFamily,
            catalog: catalog,
            allowsProFeatures: false
        )

        #expect(selection.fontFamilies == expectedFamilies(primary: systemFamily))
        #expect(selection.cjkFamily == nil)
    }

    @Test
    func freeSelectionFallsBackFromCustomPrimaryWithoutErasingPreference() {
        let selection = TerminalFontSelectionPolicy.resolve(
            primaryFamily: customFamily,
            cjkFamily: "",
            catalog: catalog,
            allowsProFeatures: false
        )

        #expect(selection.fontFamilies == expectedFamilies(
            primary: TerminalDefaults.defaultFontName
        ))
    }

    @Test
    func missingFamiliesFallBackSafely() {
        let selection = TerminalFontSelectionPolicy.resolve(
            primaryFamily: "Missing Primary",
            cjkFamily: "Missing CJK",
            catalog: catalog,
            allowsProFeatures: true
        )

        #expect(selection == .defaultValue)
    }

    @Test
    func onlyCustomAndUnknownPrimarySelectionsRequirePro() {
        #expect(!TerminalFontSelectionPolicy.primarySelectionRequiresPro(
            systemFamily,
            catalog: catalog
        ))
        #expect(TerminalFontSelectionPolicy.primarySelectionRequiresPro(
            customFamily,
            catalog: catalog
        ))
        #expect(TerminalFontSelectionPolicy.primarySelectionRequiresPro(
            "Missing Font",
            catalog: catalog
        ))
        #expect(!TerminalFontSelectionPolicy.primarySelectionRequiresPro(
            TerminalDefaults.symbolFallbackFontFamily,
            catalog: .empty
        ))
    }

    @Test
    func fallbackChainPreservesOrderAndRemovesDuplicates() {
        let selection = TerminalFontRuntimeSelection(
            primaryFamily: TerminalDefaults.symbolFallbackFontFamily,
            cjkFamily: TerminalDefaults.symbolFallbackFontFamily
        )

        #expect(selection.fontFamilies.first == TerminalDefaults.symbolFallbackFontFamily)
        #expect(
            selection.fontFamilies.filter {
                $0 == TerminalDefaults.symbolFallbackFontFamily
            }.count == 1
        )
        #expect(Set(selection.fontFamilies).count == selection.fontFamilies.count)
    }

    private var catalog: TerminalFontCatalog {
        TerminalFontCatalog(families: [
            TerminalFontFamily(
                name: TerminalDefaults.defaultFontName,
                source: .builtIn,
                isMonospaced: true
            ),
            TerminalFontFamily(name: systemFamily, source: .system, isMonospaced: true),
            TerminalFontFamily(name: customFamily, source: .custom, isMonospaced: true),
            TerminalFontFamily(name: cjkFamily, source: .custom, isMonospaced: false)
        ])
    }

    private func expectedFamilies(primary: String, cjk: String? = nil) -> [String] {
        var families = [primary]
        if let cjk {
            families.append(cjk)
        }
        families += TerminalDefaults.automaticTextFallbackFontFamilies
        families.append(TerminalDefaults.symbolFallbackFontFamily)

        var seen = Set<String>()
        return families.filter { seen.insert($0).inserted }
    }
}
