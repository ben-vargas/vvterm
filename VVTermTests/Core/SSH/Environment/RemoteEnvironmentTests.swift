import Foundation
import Testing
@testable import VVTerm

struct RemoteEnvironmentTests {
    actor FakeExecutor {
        private var outputs: [Result<String, Error>]
        private var commands: [String] = []

        init(outputs: [Result<String, Error>]) {
            self.outputs = outputs
        }

        func run(command: String, timeout _: Duration?) throws -> String {
            commands.append(command)
            guard !outputs.isEmpty else {
                Issue.record("Unexpected extra command: \(command)")
                return ""
            }
            return try outputs.removeFirst().get()
        }

        func recordedCommands() -> [String] {
            commands
        }
    }

    @Test
    func windowsPlatformDetectionRecognizesCmdVerOutput() {
        let output = "Microsoft Windows [Version 10.0.20348.2522]"
        #expect(RemotePlatform.detect(from: output) == .windows)
    }

    @Test
    func unknownPlatformDoesNotDefaultToLinux() {
        #expect(RemotePlatform.detect(from: "Plan 9") == .unknown)
    }

    @Test
    func windowsPowerShellEnvironmentSupportsTmuxButNotMoshRuntime() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "powershell"),
            activeShellName: "powershell",
            powerShellExecutable: "powershell"
        )

        #expect(environment.supportsTmuxRuntime == true)
        #expect(environment.supportsMoshRuntime == false)
        #expect(environment.supportsWorkingDirectoryRestore == true)
    }

    @Test
    func windowsCmdEnvironmentSupportsTmuxButNotMoshRuntime() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .cmd,
            activeShellName: "cmd.exe",
            powerShellExecutable: "powershell"
        )

        #expect(environment.supportsTmuxRuntime == true)
        #expect(environment.supportsMoshRuntime == false)
        #expect(environment.supportsWorkingDirectoryRestore == true)
    }

    @Test
    func windowsDefaultShellParserPrefersPwshExecutable() {
        let output = #"""
        HKEY_LOCAL_MACHINE\SOFTWARE\OpenSSH
            DefaultShell    REG_SZ    C:\Program Files\PowerShell\7\pwsh.exe
        """#

        #expect(RemoteEnvironmentResolver.powerShellExecutableName(inWindowsShellOutput: output) == "pwsh")
    }

    @Test
    func windowsPowerShellExecutableCandidatesPreferActiveShell() {
        #expect(RemoteEnvironmentResolver.powerShellExecutableCandidates(preferredExecutableName: "pwsh.exe") == ["pwsh", "powershell"])
        #expect(RemoteEnvironmentResolver.powerShellExecutableCandidates(preferredExecutableName: "powershell.exe") == ["powershell", "pwsh"])
        #expect(RemoteEnvironmentResolver.powerShellExecutableCandidates(preferredExecutableName: nil) == ["powershell", "pwsh"])
    }

    @Test
    func posixEnvironmentSupportsTmuxAndMoshRuntime() {
        let environment = RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "zsh"),
            activeShellName: "zsh",
            powerShellExecutable: nil
        )

        #expect(environment.supportsTmuxRuntime == true)
        #expect(environment.supportsMoshRuntime == true)
        #expect(environment.supportsWorkingDirectoryRestore == true)
    }

    @Test
    func posixEnvironmentUsesOneCombinedEnvironmentProbeAndOneIdentityProbe() async {
        let executor = FakeExecutor(outputs: [
            .success("__VVTERM_PLATFORM__=Linux\n__VVTERM_SHELL__=zsh"),
            .success("ID=ubuntu\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"")
        ])

        let environment = await RemoteEnvironmentResolver.resolve { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }

        #expect(environment.platform == .linux)
        #expect(environment.shellProfile.family == .posix)
        #expect(environment.activeShellName == "zsh")
        #expect(environment.systemIdentity?.kind == .ubuntu)
        #expect(environment.systemIdentity?.displayName == "Ubuntu 24.04 LTS")
        #expect(await executor.recordedCommands().count == 2)
    }

    @Test
    func windowsPowerShellEnvironmentUsesOneCombinedWindowsProbe() async {
        let executor = FakeExecutor(outputs: [
            .success(""),
            .success(
                """
                __VVTERM_PLATFORM__=Windows
                __VVTERM_DEFAULT_SHELL_BEGIN__
                HKEY_LOCAL_MACHINE\\SOFTWARE\\OpenSSH
                    DefaultShell    REG_SZ    C:\\Program Files\\PowerShell\\7\\pwsh.exe
                __VVTERM_WINDOWS_POWERSHELL_BEGIN__
                C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe
                __VVTERM_WINDOWS_PWSH_BEGIN__
                C:\\Program Files\\PowerShell\\7\\pwsh.exe
                __VVTERM_WINDOWS_PROBE_END__
                """
            ),
            .success(
                """
                __VVTERM_WINDOWS_CAPTION__=Microsoft Windows 11 Pro
                __VVTERM_WINDOWS_VERSION__=10.0.26100
                __VVTERM_WINDOWS_PRODUCT_TYPE__=1
                """
            ),
        ])

        let environment = await RemoteEnvironmentResolver.resolve { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }

        #expect(environment.platform == .windows)
        #expect(environment.shellProfile.family == .powershell)
        #expect(environment.activeShellName == "pwsh")
        #expect(environment.powerShellExecutable == "pwsh")
        #expect(environment.systemIdentity?.kind == .windows)
        #expect(environment.systemIdentity?.displayName == "Microsoft Windows 11 Pro")
        let commands = await executor.recordedCommands()
        #expect(commands.count == 3)
        #expect(commands[1] == RemoteEnvironmentResolver.windowsEnvironmentProbeCommand())
    }

    @Test
    func windowsCombinedProbeUsesCmdDefaultWhenOpenSSHHasNoOverride() {
        let environment = RemoteEnvironmentResolver.parseWindowsEnvironmentProbe(
            """
            __VVTERM_PLATFORM__=Windows
            __VVTERM_DEFAULT_SHELL_BEGIN__
            ERROR: The system was unable to find the specified registry key or value.
            __VVTERM_WINDOWS_POWERSHELL_BEGIN__
            C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe
            __VVTERM_WINDOWS_PWSH_BEGIN__
            INFO: Could not find files for the given pattern(s).
            __VVTERM_WINDOWS_PROBE_END__
            """
        )

        #expect(environment?.platform == .windows)
        #expect(environment?.shellProfile.family == .cmd)
        #expect(environment?.activeShellName == "cmd.exe")
        #expect(environment?.powerShellExecutable == "powershell")
    }

    @Test
    func nushellProfileStillCountsAsPOSIXRuntime() {
        let environment = RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "nu"),
            activeShellName: "nu",
            powerShellExecutable: nil
        )

        #expect(environment.supportsTmuxRuntime == true)
        #expect(environment.supportsMoshRuntime == true)
        #expect(environment.supportsWorkingDirectoryRestore == true)
    }

    @Test
    func windowsUnknownShellDisablesTmuxRuntimeEvenWithPowerShellAvailable() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .unknown(),
            activeShellName: nil,
            powerShellExecutable: "powershell"
        )

        #expect(environment.supportsTmuxRuntime == false)
        #expect(environment.supportsMoshRuntime == false)
        #expect(environment.supportsWorkingDirectoryRestore == false)
    }

    @Test
    func windowsUnknownShellWithoutPowerShellDisablesTmuxRuntime() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .unknown(),
            activeShellName: nil,
            powerShellExecutable: nil
        )

        #expect(environment.supportsTmuxRuntime == false)
        #expect(environment.supportsMoshRuntime == false)
        #expect(environment.supportsWorkingDirectoryRestore == false)
    }
}
