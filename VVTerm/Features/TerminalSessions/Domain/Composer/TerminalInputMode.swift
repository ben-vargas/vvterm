nonisolated enum TerminalInputMode: String, Equatable, Sendable {
    case direct
    case chat

    static let preferenceKey = "terminalInputMode"
    static let chatAccessoryPreferenceKey = "terminalChatAccessoryEnabled"
}
