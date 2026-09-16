#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalComposerEditorTests {
    @Test
    func pastedTextReplacesSelectionAndRespectsRecording() {
        let editor = ComposerTextView()
        editor.text = "before old after"
        editor.selectedRange = NSRange(location: 7, length: 3)
        editor.insertComposerText("new")
        #expect(editor.text == "before new after")
        #expect(editor.selectedRange == NSRange(location: 10, length: 0))
        editor.acceptsEdits = false
        editor.insertComposerText("blocked")
        #expect(editor.text == "before new after")
    }
}
#endif
