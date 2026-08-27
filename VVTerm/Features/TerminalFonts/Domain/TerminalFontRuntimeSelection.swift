import Foundation

nonisolated struct TerminalFontRuntimeSelection: Equatable, Sendable {
    let primaryFamily: String
    let cjkFamily: String?

    init(primaryFamily: String, cjkFamily: String?) {
        let normalizedPrimary = primaryFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCJK = cjkFamily?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.primaryFamily = normalizedPrimary.isEmpty
            ? TerminalDefaults.defaultFontName
            : normalizedPrimary
        self.cjkFamily = normalizedCJK?.isEmpty == false ? normalizedCJK : nil
    }

    var fontFamilies: [String] {
        let candidates = [primaryFamily]
            + (cjkFamily.map { [$0] } ?? [])
            + TerminalDefaults.automaticTextFallbackFontFamilies
            + [TerminalDefaults.symbolFallbackFontFamily]

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static var defaultValue: Self {
        Self(primaryFamily: TerminalDefaults.defaultFontName, cjkFamily: nil)
    }
}
