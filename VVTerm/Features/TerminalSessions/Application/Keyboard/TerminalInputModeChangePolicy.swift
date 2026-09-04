nonisolated enum TerminalInputModeChangePolicy {
    nonisolated enum Action: Equatable, Sendable {
        case activateDictation
        case commitDictation
        case invalidateLocalTextInput
    }

    static func action(
        isDictationInputModeActive: Bool,
        isDictationSessionActive: Bool
    ) -> Action {
        if isDictationInputModeActive {
            return .activateDictation
        }
        if isDictationSessionActive {
            return .commitDictation
        }
        return .invalidateLocalTextInput
    }
}
