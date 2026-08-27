#if os(iOS)
import CoreText
import UIKit

extension TerminalFontCatalog {
    @MainActor
    static func live(
        appOwnedFamilies: [TerminalFontFamily]
    ) -> TerminalFontCatalog {
        let bundledFamilies = Set(TerminalDefaults.bundledFontFamilyNames)
        let preferredSystemFamilies: Set<String> = ["Courier New", "Menlo", "SF Mono"]
        let familyNames = Set(UIFont.familyNames)
            .union(bundledFamilies)
            .union(preferredSystemFamilies)

        let families = familyNames.map { familyName in
            let fonts = UIFont.fontNames(forFamilyName: familyName).compactMap {
                UIFont(name: $0, size: 12)
            }
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
        fonts: [UIFont],
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

    private static func source(for font: UIFont) -> TerminalFontFamily.Source {
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

    private static func fontURL(_ font: UIFont) -> URL? {
        let coreTextFont = CTFontCreateWithName(font.fontName as CFString, 12, nil)
        let descriptor = CTFontCopyFontDescriptor(coreTextFont)
        return CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
    }
}
#endif
