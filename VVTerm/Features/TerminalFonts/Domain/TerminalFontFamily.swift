import Foundation

nonisolated struct TerminalFontFamily: Identifiable, Hashable, Sendable {
    nonisolated enum Source: String, CaseIterable, Hashable, Sendable {
        case builtIn
        case custom
        case system
    }

    let name: String
    let source: Source

    var id: String { name }
}
