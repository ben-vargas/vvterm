import Foundation
import Testing
@testable import VVTerm

struct RemoteShellStartupActionTests {
    @Test
    func commandPreservesShellSyntaxAndTrimsOuterWhitespace() throws {
        let action = try RemoteShellStartupAction(
            command: "  \ncd ~/myproject && tmux attach\n  "
        )

        #expect(action.command == "cd ~/myproject && tmux attach")
    }

    @Test
    func commandAllowsTabsAndNewlines() throws {
        let command = "cd ~/myproject\n\tprintf 'ready\\n'"

        #expect(try RemoteShellStartupAction(command: command).command == command)
    }

    @Test
    func commandRejectsBlankUnsupportedControlCharactersAndExcessBytes() {
        #expect(throws: RemoteShellStartupAction.ValidationError.empty) {
            try RemoteShellStartupAction(command: " \n\t ")
        }
        #expect(
            throws: RemoteShellStartupAction.ValidationError
                .containsUnsupportedControlCharacters
        ) {
            try RemoteShellStartupAction(command: "printf ready\0")
        }
        #expect(throws: RemoteShellStartupAction.ValidationError.tooLong) {
            try RemoteShellStartupAction(
                command: String(
                    repeating: "x",
                    count: RemoteShellStartupAction.maximumCommandByteCount + 1
                )
            )
        }
    }
}
