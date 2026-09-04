import Foundation
import Testing
@testable import VVTerm

private struct UnsupportedManagedStartupBackend: RemoteSessionBackend {
    let metadata = RemoteSessionBackendMetadata(
        identifier: RemoteSessionBackendIdentifier(rawValue: "unsupported-startup"),
        displayName: "Unsupported Startup",
        installation: .automatic,
        managedStartupCommandSupport: .unsupported
    )

    func availability(using client: SSHClient) async -> RemoteSessionAvailability {
        .unsupportedEnvironment
    }

    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        []
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionBackendLaunchPlan {
        RemoteSessionBackendLaunchPlan(
            command: "attach-only",
            presenceProbe: RemoteSessionPresenceProbe(
                command: "true",
                existsMarker: "exists",
                missingMarker: "missing"
            )
        )
    }

    func installScript(
        attachment: RemoteSessionAttachment,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        using client: SSHClient,
        attachAfterInstall: Bool
    ) async -> String? {
        nil
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {}

    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async -> String? {
        nil
    }
}

struct RemoteShellStartupBackendTests {
    @Test(arguments: [RemoteShellFamily.powershell, .cmd])
    func managedWindowsConfigurationUsesOneWrite(_ shellFamily: RemoteShellFamily) throws {
        let backend = TmuxRemoteSessionBackend(tmux: RemoteTmuxManager())
        let plan = try backend.launchPlan(
            for: managedAttachmentRequest(), runtime: try tmuxRuntime(shellFamily: shellFamily)
        )
        let preparation = try #require(plan.preparationCommand)
        let script: String
        if shellFamily == .cmd {
            let encoded = try #require(preparation.split(separator: " ").last)
            let data = try #require(Data(base64Encoded: String(encoded)))
            script = try #require(String(data: data, encoding: .utf16LittleEndian))
        } else {
            script = preparation
        }
        #expect(script.components(separatedBy: "Set-Content").count == 2)
    }

    @Test(arguments: [RemoteShellFamily.powershell, .cmd], [nil, "x", "'", "界"] as [String?])
    func managedWindowsLaunchFitsOpenSSHPTY(shellFamily: RemoteShellFamily, character: String?) throws {
        let initialCommand = character.map {
            String(repeating: $0, count: RemoteShellStartupAction.maximumCommandByteCount / $0.utf8.count)
        }
        let backend = TmuxRemoteSessionBackend(tmux: RemoteTmuxManager())
        let plan = try backend.launchPlan(
            for: ensureManagedRequest(initialCommand: initialCommand),
            runtime: try tmuxRuntime(shellFamily: shellFamily)
        )
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: try #require(plan.shellProfile),
            activeShellName: nil, powerShellExecutable: "powershell.exe"
        )
        #expect(environment.shellProfile.family == .powershell)
        let startupCommand: String
        if WindowsShellScript.needsTransfer(command: plan.command, environment: environment) {
            let script = try WindowsShellScript(command: plan.command, homeDirectory: "/C:/Users/O'Brien")
            #expect(String(decoding: script.contents, as: UTF8.self).hasSuffix(plan.command))
            startupCommand = script.launcher
        } else {
            startupCommand = plan.command
        }
        guard case .exec(let command) = RemoteTerminalBootstrap.launchPlan(
            startupCommand: startupCommand, environment: environment
        ) else { Issue.record("Expected a Windows exec command"); return }
        // Windows OpenSSH adds the default shell and ConPTY launcher before
        // copying into its 8,191-character buffer, including the null terminator.
        let shell = shellFamily == .cmd
            ? #""C:\Windows\System32\cmd.exe" /c "#
            : #""C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -c "#
        let completeCommand = #"C:\Windows\System32\conhost.exe --headless --width 132 --height 43 --signal 0xffff -- "#
            + shell + command
        #expect(completeCommand.utf16.count + 1 <= 8_191)
        #expect(command.utf16.count <= WindowsShellScript.directCommandLimit)
    }

    @Test
    func tmuxUsesRawCommandOnlyWhenItCreatesManagedSession() throws {
        let command = "cd /srv/custom && printf '%s' \"$(date)\""
        let runtime = try tmuxRuntime(shellFamily: .posix)
        let backend = TmuxRemoteSessionBackend(tmux: RemoteTmuxManager())

        let create = try backend.launchPlan(
            for: ensureManagedRequest(initialCommand: command),
            runtime: runtime
        ).command
        let reattach = try backend.launchPlan(
            for: managedAttachmentRequest(),
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
            for: ensureManagedRequest(initialCommand: command),
            runtime: try tmuxRuntime(shellFamily: .powershell)
        ).command
        let reattach = try backend.launchPlan(
            for: managedAttachmentRequest(),
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
            request: ensureManagedRequest(
                backendIdentifier: .zmx,
                initialCommand: command
            ),
            runtime: runtime
        )
        let reattach = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: managedAttachmentRequest(backendIdentifier: .zmx),
            runtime: runtime
        )

        #expect(create.contains("/bin/sh -lc"))
        #expect(create.contains("cd /srv/custom && printf"))
        #expect(!reattach.contains("cd /srv/custom"))
        #expect(!reattach.contains("$(date)"))
    }

    @Test
    func managedStartupActionsReportAttachment() throws {
        let attached = RemoteSessionLifecycleMarker.sequence(
            envelope: deterministicRemoteSessionLifecycleEnvelope,
            event: .attached
        )
        let tmux = try TmuxRemoteSessionBackend(tmux: RemoteTmuxManager()).launchPlan(
            for: ensureManagedRequest(initialCommand: "printf ready"),
            runtime: try tmuxRuntime(shellFamily: .posix)
        ).command
        let psmux = try TmuxRemoteSessionBackend(tmux: RemoteTmuxManager()).launchPlan(
            for: ensureManagedRequest(initialCommand: "Write-Output ready"),
            runtime: try tmuxRuntime(shellFamily: .powershell)
        ).command
        let zmx = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: ensureManagedRequest(
                backendIdentifier: .zmx,
                initialCommand: "printf ready"
            ),
            runtime: try zmxRuntime()
        )

        #expect(tmux.contains(attached))
        #expect(psmux.contains(attached))
        #expect(zmx.contains(attached))
    }

    @Test
    func unsupportedBackendRejectsNonblankManagedStartupCommandAtRuntime() async throws {
        let backend = UnsupportedManagedStartupBackend()
        let client = RemoteSessionClient(
            registry: RemoteSessionBackendRegistry(backends: [backend])
        )
        let runtime = try runtime(for: backend.metadata.identifier)
        let request = try ensureManagedRequest(
            backendIdentifier: backend.metadata.identifier,
            initialCommand: "notify-deployment"
        )

        do {
            _ = try await client.launchPlan(for: request, runtime: runtime)
            Issue.record("Expected the unsupported startup-command error")
        } catch SSHError.managedStartupCommandUnsupported(let backendName) {
            #expect(backendName == backend.metadata.displayName)
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test
    func unsupportedBackendStillAllowsBlankManagedStartupCommand() async throws {
        let backend = UnsupportedManagedStartupBackend()
        let client = RemoteSessionClient(
            registry: RemoteSessionBackendRegistry(backends: [backend])
        )
        let runtime = try runtime(for: backend.metadata.identifier)
        let request = try ensureManagedRequest(
            backendIdentifier: backend.metadata.identifier,
            initialCommand: " \n\t "
        )

        let plan = try await client.launchPlan(for: request, runtime: runtime)

        #expect(plan.command == "attach-only")
    }

    private func ensureManagedRequest(
        backendIdentifier: RemoteSessionBackendIdentifier = .tmux,
        initialCommand: String?
    ) throws -> RemoteSessionLaunchRequest {
        RemoteSessionLaunchRequest(
            intent: .ensureManaged(
                identifier: try RemoteSessionIdentifier(
                    backendIdentifier: backendIdentifier,
                    validating: "managed"
                ),
                initialCommand: initialCommand
            ),
            workingDirectory: "/srv/default",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )
    }

    private func managedAttachmentRequest(
        backendIdentifier: RemoteSessionBackendIdentifier = .tmux
    ) throws -> RemoteSessionLaunchRequest {
        RemoteSessionLaunchRequest(
            intent: .attach(RemoteSessionAttachment(
                identifier: try RemoteSessionIdentifier(
                    backendIdentifier: backendIdentifier,
                    validating: "managed"
                ),
                ownership: .managed
            )),
            workingDirectory: "/srv/default",
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

    private func runtime(
        for backendIdentifier: RemoteSessionBackendIdentifier
    ) throws -> RemoteSessionRuntime {
        RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: backendIdentifier,
            executable: try RemoteSessionExecutable(validating: "/opt/tools/backend"),
            implementationVariant: "test",
            rawVersion: "1.0.0",
            semanticVersion: RemoteSessionSemanticVersion("1.0.0"),
            shellFamily: .posix,
            shellExecutable: "/bin/sh"
        ))
    }
}
