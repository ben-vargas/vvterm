nonisolated enum TerminalInputMode: String, Equatable, Sendable {
    case direct
    case chat

    static let preferenceKey = "terminalInputMode"
}
