#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

struct RemotePsmuxProbeIntegrationTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pwsh")),
          arguments: [false, true], [RemoteShellFamily.powershell, .cmd])
    func managedConfigurationAndLaunchParse(reattach: Bool, shellFamily: RemoteShellFamily) throws {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "C:\\Program Files\\psmux\\psmux.exe",
            shellFamily: shellFamily, powerShellExecutable: "pwsh"
        )
        let command = reattach ? RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "managed", ownership: .managed, backend: backend
        ) : RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "managed", workingDirectory: "C:\\Work", backend: backend
        )
        let preparation = try #require(RemoteTmuxCommandBuilder.separateManagedConfigurationCommand(
            themeStyle: deterministicRemoteSessionThemeStyle, backend: backend
        ))
        let script = try [preparation, command].map { command in
            guard shellFamily == .cmd else { return command }
            let encoded = try #require(command.split(separator: " ").last)
            let data = try #require(Data(base64Encoded: String(encoded)))
            return try #require(String(data: data, encoding: .utf16LittleEndian))
        }.joined(separator: "\n")
        let encoded = Data(script.utf8).base64EncodedString()
        let check = """
        $script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encoded)'))
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { $errors | Out-String | Write-Output; exit 1 }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pwsh")
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", check]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: data, as: UTF8.self))")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pwsh")),
          arguments: [false, true])
    func nativeVersionOutputIsConsumedOnce(requireAliasCheck: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-psmux-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("psmux")
        let calls = directory.appendingPathComponent("calls")
        let fixture = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "$VVTERM_TEST_PROBE_CALLS"
        case "$1" in
          -V) printf 'tmux 3.3.7\r\npsmux 3.3.7\r\n' ;;
          list-commands) printf 'dump-state\nclaim-session\n' ;;
          *) exit 1 ;;
        esac
        """#
        try Data(fixture.utf8).write(to: executable)
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: executable.path, shellFamily: .powershell, powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxCommandBuilder.windowsPsmuxAvailabilityProbeCommand(
            commandName: executable.path, backend: backend, requirePsmuxExtension: requireAliasCheck
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pwsh")
        // The app sandbox cannot execute a newly written file. Use the system
        // shell for the native fixture while testing PowerShell output handling.
        let fixturePath = executable.path.replacingOccurrences(of: "'", with: "''")
        let script = """
        function Invoke-VVTermProbeFixture { & /bin/sh '\(fixturePath)' @args; $global:LASTEXITCODE = $LASTEXITCODE }
        function Get-Command { [pscustomobject]@{ Source = 'Invoke-VVTermProbeFixture' } }
        \(command)
        """
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", script]
        var environment = ProcessInfo.processInfo.environment
        environment["VVTERM_TEST_PROBE_CALLS"] = calls.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("__VVTERM_TMUX_OK__:" + executable.path))
        #expect(text.contains("__VVTERM_TMUX_PATH__Invoke-VVTermProbeFixture"))
        #expect(text.contains("__VVTERM_TMUX_VERSION__tmux 3.3.7"))
        let invocations = try String(contentsOf: calls, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        #expect(invocations == (requireAliasCheck ? ["-V", "list-commands"] : ["-V"]))
    }
}
#endif
