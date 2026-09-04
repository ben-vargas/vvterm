import Foundation
import Testing
@testable import VVTerm

struct RemotePsmuxCommandBuilderTests {
    @Test
    func managedStartupFitsCmdInvocation() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux", shellFamily: .cmd, powerShellExecutable: "powershell.exe"
        )
        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "vvterm_managed_session",
            workingDirectory: #"C:\Users\VVTerm\project"#,
            backend: backend,
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope
        )
        #expect(RemoteTerminalBootstrap.wrapCmdExecCommand(command).utf16.count <= 8_191)
    }

    @Test(arguments: [false, true])
    func availabilityRunsVersionOnceAndChecksOnlyAliases(_ isAlias: Bool) {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: isAlias ? "tmux" : "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxCommandBuilder.windowsPsmuxAvailabilityProbeCommand(
            commandName: backend.commandName, backend: backend, requirePsmuxExtension: isAlias
        )
        #expect(command.components(separatedBy: " -V").count == 2)
        #expect(command.contains("list-commands") == isAlias)
        #expect(command.contains("@(& $cmd.Source -V 2>$null)"))
    }

    @Test(arguments: ["x", "'"])
    func maximumStartupActionRequiresScriptTransfer(_ character: String) throws {
        let action = try RemoteShellStartupAction(
            command: String(
                repeating: character,
                count: RemoteShellStartupAction.maximumCommandByteCount
            )
        )
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "powershell.exe"
        )
        let backendCommand = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "vvterm_managed_session",
            workingDirectory: #"C:\Users\VVTerm\project"#,
            initialCommand: action.command,
            backend: backend,
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope
        )
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "powershell.exe"),
            activeShellName: "powershell.exe",
            powerShellExecutable: "powershell.exe"
        )
        #expect(WindowsShellScript.needsTransfer(command: backendCommand, environment: environment))
    }

    @Test
    func externalWindowsSessionAttachDoesNotLoadVVTermConfiguration() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "external team; session",
            ownership: .external,
            backend: backend
        )

        #expect(command.contains("attach-session -d -t $vvtermSession"))
        #expect(!command.contains("source-file"))
        #expect(!command.contains("$vvtermConfig"))
    }

    @Test
    func managedWindowsSessionAttachLoadsVVTermConfiguration() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "vvterm_managed",
            ownership: .managed,
            backend: backend
        )

        #expect(command.contains("source-file -t $vvtermSession $vvtermConfig"))
        #expect(!command.contains("Set-Content"))
        #expect(command.contains("-u attach-session"))
    }

    @Test
    func managedWindowsConfigUsesActivePowerShellExecutableAsDefaultShellOnce() throws {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = try #require(RemoteTmuxCommandBuilder.separateManagedConfigurationCommand(
            themeStyle: deterministicRemoteSessionThemeStyle, backend: backend
        ))

        #expect(command.contains("[System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName"))
        #expect(command.contains("set -o default-shell"))
        #expect(!command.contains("set -g default-shell"))
    }

    @Test
    func managedWindowsConfigUsesComSpecAsCmdDefaultShellOnce() throws {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .cmd,
            powerShellExecutable: "powershell"
        )

        let command = try #require(RemoteTmuxCommandBuilder.separateManagedConfigurationCommand(
            themeStyle: deterministicRemoteSessionThemeStyle, backend: backend
        ))
        let script = try #require(decodedPowerShellScript(from: command))

        #expect(script.contains("$vvtermDefaultShell = $env:ComSpec"))
        #expect(script.contains("set -o default-shell"))
        #expect(!script.contains("set -g default-shell"))
    }

    @Test
    func windowsPsmuxAttachCommandUsesPowerShellAndPsmux() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "vvterm_demo",
            workingDirectory: "C:/Users/me/project",
            backend: backend
        )

        #expect(command.contains("$vvtermPsmux = 'psmux'"))
        #expect(command.contains("has-session -t $vvtermSession"))
        #expect(command.contains("attach-session -d -t $vvtermSession"))
        #expect(command.contains("new-session -s $vvtermSession -c $vvtermWorkingDirectory"))
        #expect(!command.contains("new-session -A"))
        #expect(command.contains("#{@vvterm-managed}"))
        #expect(command.contains("[Convert]::FromBase64String('QzpcVXNlcnNcbWVccHJvamVjdA==')"))
        #expect(command.contains("$HOME + '\\.vvterm\\psmux.conf'"))
        #expect(!command.contains("$vvtermExactSession"))
        #expect(!command.contains("sh -lc"))
        #expect(!command.contains("export PATH"))
        #expect(!command.contains("mkdir -p"))
        #expect(!command.contains("printf"))
        #expect(!command.contains("uname"))
        #expect(!command.contains("exec tmux"))
    }

    @Test(arguments: [
        "C:/work/$(Get-Process)",
        "C:/work/`Get-Process`",
        "C:/work/$env:USERPROFILE",
        "C:/work/O'Hara",
        "C:/work/line\nbreak",
        "C:/work/ユニコード",
        "-leading-option"
    ])
    func windowsWorkingDirectoryIsOneOpaquePowerShellArgument(_ workingDirectory: String) {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "vvterm_secure",
            workingDirectory: workingDirectory,
            backend: backend
        )
        let normalized = workingDirectory.replacingOccurrences(of: "/", with: "\\")
        let encoded = Data(normalized.utf8).base64EncodedString()
        let expression = "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encoded)'))"

        #expect(command.contains("$vvtermWorkingDirectory = \(expression)"))
        #expect(command.contains("-c $vvtermWorkingDirectory"))
    }

    @Test
    func unsupportedWindowsShellProfileDoesNotGeneratePsmuxCommand() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .unknown,
            powerShellExecutable: nil
        )

        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "vvterm_secure",
            workingDirectory: "C:/work",
            backend: backend
        )

        #expect(command.isEmpty)
    }

    @Test
    func windowsPsmuxLifecycleCommandReportsDetachOrSessionEnd() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "vvterm_demo",
            workingDirectory: "C:/work",
            backend: backend,
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope
        )

        #expect(command.contains("has-session -t $vvtermSession"))
        #expect(command.contains("[Console]::Out.Write"))
        #expect(command.contains("marker-token"))
        #expect(command.contains("detached"))
        #expect(command.contains("terminated"))
        #expect(command.contains("creationFailed"))
        #expect(command.contains("$vvtermTmuxCreateStatus = $LASTEXITCODE"))
    }

    @Test
    func windowsCmdPsmuxAttachCommandWrapsPowerShell() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "pmux",
            shellFamily: .cmd,
            powerShellExecutable: "powershell"
        )

        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "shared",
            ownership: .external,
            backend: backend
        )

        #expect(command.hasPrefix("powershell -NoLogo -NoProfile -EncodedCommand "))
    }

    @Test
    func windowsPowerShellAttachExistingFallsBackToInteractiveShell() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "shared",
            ownership: .external,
            backend: backend
        )

        #expect(command.contains("} else {"))
        #expect(command.contains("& 'pwsh'"))
    }

    @Test
    func windowsPsmuxAvailabilityProbeConfirmsTmuxAliasWithPsmuxExtension() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "tmux",
            shellFamily: .powershell,
            powerShellExecutable: "powershell"
        )

        let probe = RemoteTmuxCommandBuilder.windowsPsmuxAvailabilityProbeCommand(
            commandName: "tmux",
            backend: backend,
            requirePsmuxExtension: true
        )

        #expect(probe.contains("Get-Command 'tmux'"))
        #expect(probe.contains("list-commands"))
        #expect(probe.contains("dump-state"))
        #expect(probe.contains("claim-session"))
        #expect(probe.contains("__VVTERM_TMUX_OK__:tmux"))
        #expect(probe.contains("__VVTERM_TMUX_NO__:tmux"))
    }

    @Test
    func windowsPsmuxInstallScriptUsesWindowsPackageManagersAndConfig() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let script = RemoteTmuxCommandBuilder.installAndAttachScript(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "vvterm_demo",
            workingDirectory: "C:/work",
            terminalType: .xtermGhostty,
            backend: backend
        )

        #expect(script.contains("Set-Content -Encoding UTF8 -NoNewline -Path $vvtermConfigPath"))
        #expect(script.contains("$HOME + '\\.vvterm\\psmux.conf'"))
        #expect(script.contains("winget install --id marlocarlo.psmux"))
        #expect(script.contains("scoop bucket add psmux https://github.com/psmux/scoop-psmux"))
        #expect(script.contains("choco install psmux -y"))
        #expect(script.contains("cargo install psmux"))
        #expect(script.contains("function Get-VVTermPsmuxCommand"))
        #expect(script.contains("Get-Command pmux -ErrorAction SilentlyContinue"))
        #expect(script.contains("$vvtermPsmux = $vvtermPsmuxCommand.Source"))
        #expect(script.contains("set -g allow-set-title on"))
        #expect(!script.contains("%if"))
        #expect(script.contains("set -g terminal-features[0] \"*:hyperlinks\""))
        #expect(!script.contains("irm "))
        #expect(!script.contains("WheelUpPane"))
        #expect(!script.contains("WheelDownPane"))
        #expect(!script.contains("scroll-on-clear"))
        #expect(!script.contains("sh -lc"))
    }

    private func decodedPowerShellScript(from command: String) -> String? {
        guard let encodedCommand = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .last,
              let data = Data(base64Encoded: String(encodedCommand)) else {
            return nil
        }
        return String(data: data, encoding: .utf16LittleEndian)
    }
}
