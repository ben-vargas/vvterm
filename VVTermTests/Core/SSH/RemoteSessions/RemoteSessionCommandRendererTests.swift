import Foundation
import Testing
@testable import VVTerm

struct RemoteSessionCommandRendererTests {
    private let executable = try! RemoteSessionExecutable(validating: "/opt/tools/zmx")

    @Test
    func posixRendererKeepsValuesOpaqueAndClearsRequestedEnvironment() throws {
        let command = try RemoteSessionCommandRenderer.render(
            RemoteSessionCommandPlan(
                executable: executable,
                arguments: ["attach", "team '$(touch /tmp/no)'"],
                environment: ["SAFE_VALUE": "$HOME"],
                environmentRemovals: ["ZMX_SESSION"],
                workingDirectory: "/tmp/$(touch no)"
            ),
            for: .posix
        )

        #expect(command.contains("env '-u' 'ZMX_SESSION'"))
        #expect(command.contains("SAFE_VALUE='$HOME'"))
        let invocation = ["/opt/tools/zmx", "attach", "team '$(touch /tmp/no)'"]
            .map(RemoteTerminalBootstrap.shellQuoted)
            .joined(separator: " ")
        #expect(command.contains(invocation))
        #expect(command.hasPrefix("cd '/tmp/$(touch no)' && "))
    }

    @Test
    func powershellRendererUsesLiteralArgumentsAndEnvironment() throws {
        let command = try RemoteSessionCommandRenderer.render(
            RemoteSessionCommandPlan(
                executable: executable,
                arguments: ["attach", "O'Hara;$env:USER"],
                environment: ["SAFE_VALUE": "O'Hara"],
                environmentRemovals: ["ZMX_SESSION"],
                workingDirectory: "C:\\Work;Remove-Item"
            ),
            for: .powershell
        )

        #expect(command.contains("Remove-Item Env:ZMX_SESSION"))
        #expect(command.contains("$env:SAFE_VALUE = 'O''Hara'"))
        #expect(command.contains("Set-Location -LiteralPath 'C:\\Work;Remove-Item'"))
        #expect(command.contains("'O''Hara;$env:USER'"))
    }

    @Test
    func commandPromptRendererUsesAnEncodedPowerShellBoundary() throws {
        let command = try RemoteSessionCommandRenderer.render(
            RemoteSessionCommandPlan(
                executable: try RemoteSessionExecutable(validating: "C:\\Tools\\zmx.exe"),
                arguments: ["attach", "%PATH% & calc.exe 'quoted' !value!"],
                environmentRemovals: ["ZMX_SESSION"]
            ),
            for: .cmd
        )
        let prefix = "powershell.exe -NoLogo -NoProfile -EncodedCommand "
        let encoded = String(command.dropFirst(prefix.count))
        let data = try #require(Data(base64Encoded: encoded))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))

        #expect(command.hasPrefix(prefix))
        #expect(!encoded.contains("&"))
        #expect(script.contains("Remove-Item Env:ZMX_SESSION"))
        #expect(script.contains("'%PATH% & calc.exe ''quoted'' !value!'"))
    }

    @Test
    func rendererRejectsUnknownShellAndInvalidEnvironmentNames() {
        let plan = RemoteSessionCommandPlan(
            executable: executable,
            environment: ["BAD-NAME": "value"]
        )

        #expect(throws: RemoteSessionCommandRenderer.RenderError.invalidEnvironmentName) {
            try RemoteSessionCommandRenderer.render(plan, for: .posix)
        }
        #expect(throws: RemoteSessionCommandRenderer.RenderError.unsupportedShell) {
            try RemoteSessionCommandRenderer.render(
                RemoteSessionCommandPlan(executable: executable),
                for: .unknown
            )
        }
    }

    @Test
    func rendererBoundsArgumentCountAndTotalInputSize() {
        #expect(throws: RemoteSessionCommandRenderer.RenderError.tooManyArguments) {
            try RemoteSessionCommandRenderer.render(
                RemoteSessionCommandPlan(
                    executable: executable,
                    arguments: Array(repeating: "x", count: 257)
                ),
                for: .posix
            )
        }
        #expect(throws: RemoteSessionCommandRenderer.RenderError.commandTooLong) {
            try RemoteSessionCommandRenderer.render(
                RemoteSessionCommandPlan(
                    executable: executable,
                    arguments: Array(repeating: String(repeating: "x", count: 16_000), count: 5)
                ),
                for: .posix
            )
        }
    }
}
