import Testing
@testable import VVTerm

struct TerminalInputModeChangePolicyTests {
    @Test
    func dictationInputModeActivatesDictation() {
        #expect(
            TerminalInputModeChangePolicy.action(
                isDictationInputModeActive: true,
                isDictationSessionActive: false
            ) == .activateDictation
        )
        #expect(
            TerminalInputModeChangePolicy.action(
                isDictationInputModeActive: true,
                isDictationSessionActive: true
            ) == .activateDictation
        )
    }

    @Test
    func leavingDictationCommitsIt() {
        #expect(
            TerminalInputModeChangePolicy.action(
                isDictationInputModeActive: false,
                isDictationSessionActive: true
            ) == .commitDictation
        )
    }

    @Test
    func regularKeyboardChangeInvalidatesOnlyLocalTextInput() {
        #expect(
            TerminalInputModeChangePolicy.action(
                isDictationInputModeActive: false,
                isDictationSessionActive: false
            ) == .invalidateLocalTextInput
        )
    }
}
