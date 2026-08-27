import Foundation

nonisolated struct TerminalFontPreference: Codable, Equatable, Sendable {
    static var defaultValue: Self {
        Self(
            primaryFamily: TerminalDefaults.defaultFontName,
            cjkFamily: nil,
            updatedAt: .distantPast
        )
    }

    let primaryFamily: String
    let cjkFamily: String?
    let updatedAt: Date

    init(
        primaryFamily: String,
        cjkFamily: String?,
        updatedAt: Date
    ) {
        let selection = TerminalFontRuntimeSelection(
            primaryFamily: primaryFamily,
            cjkFamily: cjkFamily
        )
        self.primaryFamily = selection.primaryFamily
        self.cjkFamily = selection.cjkFamily
        self.updatedAt = updatedAt
    }
}
