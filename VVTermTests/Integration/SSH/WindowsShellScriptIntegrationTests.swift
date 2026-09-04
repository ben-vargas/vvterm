#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pwsh")))
struct WindowsShellScriptIntegrationTests {
    @Test(arguments: [nil, Int32(0), Int32(23)])
    func sessionRemovalReportsMissingExecutablesAndNativeFailures(_ exitStatus: Int32?) throws {
        let commandName = "vvterm-test-missing-backend-425f"
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: commandName, shellFamily: .powershell, powerShellExecutable: "pwsh"
        )
        let fixture = exitStatus.map {
            "function \(commandName) { & /bin/sh -c 'exit \($0)'; $global:LASTEXITCODE = $LASTEXITCODE }\n"
        } ?? ""
        let result = try run(fixture + RemoteTmuxCommandBuilder.killSessionCommand(named: "test", backend: backend))
        #expect((result.status == 0) == (exitStatus == 0), "\(result.errors)")
    }

    @Test(arguments: [false, true])
    func transferredScriptIsDeletedBeforeExecutingExactlyOnce(failAction: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vvterm-startup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("O'Brien.ps1")
        let quoted = RemoteTerminalBootstrap.powerShellQuoted(file.path)
        let command = """
        if ([IO.File]::Exists(\(quoted))) { throw 'script was not deleted' }
        Write-Output 'Привет 世界'
        \(failAction ? "exit 23" : "exit 0")
        """
        try Data(command.utf8).write(to: file)
        let result = try run(WindowsShellScript.launcher(path: file.path))
        #expect(result.status == (failAction ? 23 : 0), "\(result.output)")
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Привет 世界")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let repeated = try run(WindowsShellScript.launcher(path: file.path))
        #expect(repeated.status != 0)
        #expect(!repeated.output.contains("Привет 世界"))
    }

    @Test(arguments: ["New-Item", "Set-Content"])
    func configurationWriteFailureTerminatesPreparation(_ operation: String) throws {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux", shellFamily: .powershell, powerShellExecutable: "pwsh"
        )
        let command = try #require(RemoteTmuxCommandBuilder.separateManagedConfigurationCommand(
            themeStyle: deterministicRemoteSessionThemeStyle, backend: backend
        ))
        let script = """
        function New-Item { [CmdletBinding()] param($ItemType, [switch]$Force, $Path) }
        function Set-Content { [CmdletBinding()] param($Encoding, [switch]$NoNewline, $Path) }
        function \(operation) {
          [CmdletBinding()] param($ItemType, [switch]$Force, $Encoding, [switch]$NoNewline, $Path)
          Write-Error 'configuration permission denied'
        }
        \(command)
        Write-Output 'unexpected continuation'
        """
        let result = try run(script)
        #expect(result.status != 0)
        #expect(result.errors.contains("configuration permission denied"))
        #expect(!result.output.contains("unexpected continuation"))
    }

    private func run(_ script: String) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pwsh")
        process.arguments = ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }
}
#endif
