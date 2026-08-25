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

    @Test
    func maximumCommandFitsTheWindowsPowerShellCommandLine() throws {
        let action = try RemoteShellStartupAction(
            command: String(
                repeating: "x",
                count: RemoteShellStartupAction.maximumCommandByteCount
            )
        )
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "powershell.exe"),
            activeShellName: "powershell.exe",
            powerShellExecutable: "powershell.exe"
        )
        let plan = RemoteTerminalBootstrap.launchPlan(
            startupCommand: action.command,
            environment: environment
        )
        guard case .exec(let command) = plan else {
            Issue.record("Expected a PowerShell startup command")
            return
        }

        #expect(command.utf16.count <= 32_767)
    }
}
