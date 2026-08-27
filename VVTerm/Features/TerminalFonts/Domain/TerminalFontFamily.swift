import Foundation

nonisolated struct TerminalFontFamily: Identifiable, Hashable, Sendable {
    nonisolated enum Source: String, CaseIterable, Hashable, Sendable {
        case builtIn
        case system
        case custom
    }

    let name: String
    let source: Source
    let isMonospaced: Bool

    var id: String { name }
}
