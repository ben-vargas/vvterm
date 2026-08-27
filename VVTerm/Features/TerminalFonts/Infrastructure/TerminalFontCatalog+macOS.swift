#if os(macOS)
import AppKit
import CoreText

extension TerminalFontCatalog {
    @MainActor
    static func live(
        appOwnedFamilies: [TerminalFontFamily]
    ) -> TerminalFontCatalog {
        let fontManager = NSFontManager.shared
        let bundledFamilies = Set(TerminalDefaults.bundledFontFamilyNames)
        let familyNames = Set(fontManager.availableFontFamilies).union(bundledFamilies)

        let families = familyNames.map { familyName in
            let memberNames = fontManager.availableMembers(ofFontFamily: familyName)?
                .compactMap { $0.first as? String } ?? []
            let fonts = memberNames.compactMap { NSFont(name: $0, size: 12) }
            let source = fontSource(
                familyName: familyName,
                fonts: fonts,
                bundledFamilies: bundledFamilies
            )
            return TerminalFontFamily(
                name: familyName,
                source: source
            )
        }

        return TerminalFontCatalog(families: families + appOwnedFamilies)
    }

    private static func fontSource(
        familyName: String,
        fonts: [NSFont],
        bundledFamilies: Set<String>
    ) -> TerminalFontFamily.Source {
        guard !bundledFamilies.contains(familyName) else { return .builtIn }

        let sources = fonts.map(source)
        if sources.contains(.custom) {
            return .custom
        }
        if sources.contains(.builtIn) {
            return .builtIn
        }
        return .system
    }

    private static func source(for font: NSFont) -> TerminalFontFamily.Source {
        guard let url = fontURL(font) else { return .system }
        let path = url.standardizedFileURL.path
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path

        if path == bundlePath || path.hasPrefix(bundlePath + "/") {
            return .builtIn
        }
        if path.hasPrefix("/System/Library/") || path.hasPrefix("/Library/Apple/") {
            return .system
        }
        return .custom
    }

    private static func fontURL(_ font: NSFont) -> URL? {
        let descriptor = CTFontCopyFontDescriptor(font as CTFont)
        return CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
    }
}
#endif
