import Foundation
import Testing
@testable import VVTerm

struct RemoteShellStartupBackendTests {
    @Test
    func tmuxUsesRawCommandOnlyWhenItCreatesManagedSession() throws {
        let command = "cd /srv/custom && printf '%s' \"$(date)\""
        let runtime = try tmuxRuntime(shellFamily: .posix)
        let backend = TmuxRemoteSessionBackend(tmux: RemoteTmuxManager())

        let create = try backend.launchPlan(
            for: request(mode: .attachOrCreate, initialCommand: command),
            runtime: runtime
        ).command
        let reattach = try backend.launchPlan(
            for: request(mode: .attachExisting, initialCommand: command),
            runtime: runtime
        ).command

        #expect(create.contains("cd /srv/custom"))
        #expect(create.contains("printf"))
        #expect(!reattach.contains("cd /srv/custom"))
        #expect(!reattach.contains("$(date)"))
    }

    @Test
    func psmuxReceivesRawCommandOnlyForSessionCreation() throws {
        let command = "Set-Location C:\\Work; Write-Output \"ready\""
        let backend = TmuxRemoteSessionBackend(tmux: RemoteTmuxManager())

        let create = try backend.launchPlan(
            for: request(mode: .attachOrCreate, initialCommand: command),
            runtime: try tmuxRuntime(shellFamily: .powershell)
        ).command
        let reattach = try backend.launchPlan(
            for: request(mode: .attachExisting, initialCommand: command),
            runtime: try tmuxRuntime(shellFamily: .powershell)
        ).command

        #expect(create.contains("Set-Location C:\\Work"))
        #expect(!reattach.contains("Set-Location C:\\Work"))
    }

    @Test
    func zmxUsesShellCommandOnlyForMissingSessionBranch() throws {
        let command = "cd /srv/custom && printf '%s' \"$(date)\""
        let runtime = try zmxRuntime()

        let create = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request(
                backendIdentifier: .zmx,
                mode: .attachOrCreate,
                initialCommand: command
            ),
            runtime: runtime
        )
        let reattach = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request(
                backendIdentifier: .zmx,
                mode: .attachExisting,
                initialCommand: command
            ),
            runtime: runtime
        )

        #expect(create.contains("'/bin/sh' '-lc'"))
        #expect(create.contains("cd /srv/custom && printf"))
        #expect(!reattach.contains("cd /srv/custom"))
        #expect(!reattach.contains("$(date)"))
    }

    private func request(
        backendIdentifier: RemoteSessionBackendIdentifier = .tmux,
        mode: RemoteSessionLaunchMode,
        initialCommand: String?
    ) throws -> RemoteSessionLaunchRequest {
        RemoteSessionLaunchRequest(
            attachment: RemoteSessionAttachment(
                identifier: try RemoteSessionIdentifier(
                    backendIdentifier: backendIdentifier,
                    validating: "managed"
                ),
                ownership: .managed
            ),
            mode: mode,
            workingDirectory: "/srv/default",
            initialCommand: initialCommand,
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )
    }

    private func tmuxRuntime(
        shellFamily: RemoteShellFamily
    ) throws -> RemoteSessionRuntime {
        let isWindows = shellFamily != .posix
        return RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: try RemoteSessionExecutable(
                validating: isWindows ? "C:\\Tools\\psmux.exe" : "/opt/tools/tmux"
            ),
            implementationVariant: isWindows ? "windows-psmux" : "unix-tmux",
            rawVersion: "3.5",
            semanticVersion: RemoteSessionSemanticVersion("3.5"),
            shellFamily: shellFamily,
            shellExecutable: isWindows ? "powershell" : "/bin/sh"
        ))
    }

    private func zmxRuntime() throws -> RemoteSessionRuntime {
        RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .zmx,
            executable: try RemoteSessionExecutable(validating: "/opt/tools/zmx"),
            implementationVariant: "zmx",
            rawVersion: "0.7.0",
            semanticVersion: RemoteSessionSemanticVersion("0.7.0"),
            shellFamily: .posix,
            shellExecutable: "/bin/sh"
        ))
    }
}
