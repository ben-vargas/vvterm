#if os(macOS)
import AppKit
import Testing
@testable import VVTerm

@MainActor
struct TerminalFontCatalogMacOSTests {
    @Test
    func installedFontsAreSystemUnlessBundledWithVVTerm() {
        let catalog = TerminalFontCatalog.live(appOwnedFamilies: [])
        let bundled = Set(TerminalDefaults.bundledFontFamilyNames)

        for family in catalog.families {
            #expect(family.source == (bundled.contains(family.name) ? .builtIn : .system),
                    "Unexpected source for \(family.name)")
        }
        #expect(Set(NSFontManager.shared.availableFontFamilies).isSubset(of: Set(catalog.families.map(\.name))))
    }

    @Test
    func onlyImportedFamiliesAppearInCustomGroup() throws {
        let installedName = try #require(NSFontManager.shared.availableFontFamilies.first {
            !TerminalDefaults.bundledFontFamilyNames.contains($0)
        })
        let imports = [
            TerminalFontFamily(name: installedName, source: .custom),
            TerminalFontFamily(name: "VVTerm Imported Test Family", source: .custom)
        ]
        let catalog = TerminalFontCatalog.live(appOwnedFamilies: imports)

        #expect(Set(catalog.families.filter { $0.source == .custom }.map(\.name)) == Set(imports.map(\.name)))
        #expect(catalog.families.filter { $0.name == installedName }.count == 1)
    }
}
#endif
