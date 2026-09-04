import Foundation
import Testing
@testable import VVTerm

struct WindowsShellScriptTests {
    private let environment = RemoteEnvironment(
        platform: .windows, shellProfile: .powershell(executableName: "powershell.exe"),
        activeShellName: "powershell.exe", powerShellExecutable: "powershell.exe"
    )

    @Test(arguments: ["x", "'", "界"])
    func largeCommandsUseShortLaunchers(_ character: String) throws {
        let command = String(repeating: character, count: 4_000 / character.utf8.count)
        let script = try WindowsShellScript(command: command, homeDirectory: "/C:/Users/O'Brien")
        #expect(String(decoding: script.contents, as: UTF8.self).hasSuffix(command))
        #expect(!WindowsShellScript.needsTransfer(command: script.launcher, environment: environment))
        #expect(script.launcher.contains("O''Brien"))
        let deletion = try #require(script.launcher.range(of: "::Delete"))
        let invocation = try #require(script.launcher.range(of: "ScriptBlock"))
        #expect(deletion.lowerBound < invocation.lowerBound)
    }

    @Test
    func shortCommandsDoNotTransfer() {
        #expect(!WindowsShellScript.needsTransfer(command: "Write-Output ready", environment: environment))
        #expect(!WindowsShellScript.needsTransfer(command: nil, environment: environment))
        #expect(WindowsShellScript.needsTransfer(command: String(repeating: "x", count: 4_000), environment: environment))
    }

    @Test
    func longEscapedPathsAreMeasuredAfterEncoding() throws {
        let script = try WindowsShellScript(command: "echo ok", homeDirectory: "C:/" + String(repeating: "'", count: 2_000))
        #expect(WindowsShellScript.needsTransfer(command: script.launcher, environment: environment))
    }
}
