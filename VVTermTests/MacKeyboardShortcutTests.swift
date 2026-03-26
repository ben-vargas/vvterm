#if os(macOS)
import AppKit
import Testing
@testable import VVTerm

struct MacKeyboardShortcutTests {
    @Test
    func newWindowShortcutMatchesCommandN() {
        #expect(MacAppShortcutTrigger.matching(keyCode: Ghostty.Input.Key.n.keyCode!, modifiers: .command) == .newWindow)
    }

    @Test
    func settingsShortcutMatchesCommandComma() {
        #expect(MacAppShortcutTrigger.matching(keyCode: Ghostty.Input.Key.comma.keyCode!, modifiers: .command) == .openSettings)
    }

    @Test
    func previousTabShortcutMatchesCommandShiftLeftBracket() {
        #expect(MacAppShortcutTrigger.matching(keyCode: Ghostty.Input.Key.bracketLeft.keyCode!, modifiers: [.command, .shift]) == .previousTab)
    }

    @Test
    func commandVMatchesPhysicalVKey() {
        #expect(MacTerminalShortcut.paste.matches(keyCode: Ghostty.Input.Key.v.keyCode!, modifiers: .command))
    }

    @Test
    func commandVIgnoresNonShortcutModifiersLikeCapsLock() {
        #expect(MacTerminalShortcut.paste.matches(keyCode: Ghostty.Input.Key.v.keyCode!, modifiers: [.command, .capsLock]))
    }

    @Test
    func commandVRejectsWrongModifierSet() {
        #expect(MacTerminalShortcut.paste.matches(keyCode: Ghostty.Input.Key.v.keyCode!, modifiers: [.command, .shift]) == false)
    }

    @Test
    func commandCMatchesPhysicalCKey() {
        #expect(MacTerminalShortcut.copy.matches(keyCode: Ghostty.Input.Key.c.keyCode!, modifiers: .command))
    }

    @Test
    func controlVMatchesRichPasteShortcut() {
        #expect(MacTerminalShortcut.richPaste.matches(keyCode: Ghostty.Input.Key.v.keyCode!, modifiers: .control))
    }

    @Test
    func voiceShortcutMatchesCommandShiftM() {
        #expect(MacTerminalShortcut.toggleVoiceRecording.matches(keyCode: Ghostty.Input.Key.m.keyCode!, modifiers: [.command, .shift]))
    }

    @Test
    func commandShiftDUsesSplitDownBeforeDiscovery() {
        var recorded: [String] = []
        let actions = MacAppShortcutActions(
            discoverLocalDevices: { recorded.append("discover") },
            splitDown: { recorded.append("split") }
        )

        let handled = actions.perform(.splitDownOrDiscoverLocalDevices)

        #expect(handled)
        #expect(recorded == ["split"])
    }

    @Test
    func commandShiftDFallsBackToDiscoveryWhenSplitIsUnavailable() {
        var recorded: [String] = []
        let actions = MacAppShortcutActions(
            discoverLocalDevices: { recorded.append("discover") }
        )

        let handled = actions.perform(.splitDownOrDiscoverLocalDevices)

        #expect(handled)
        #expect(recorded == ["discover"])
    }

    @Test
    func neighboringKeyDoesNotMatchShortcut() {
        #expect(MacTerminalShortcut.paste.matches(keyCode: Ghostty.Input.Key.c.keyCode!, modifiers: .command) == false)
    }
}
#endif
