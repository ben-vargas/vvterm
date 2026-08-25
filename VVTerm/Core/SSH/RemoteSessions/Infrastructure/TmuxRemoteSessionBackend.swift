import Foundation

nonisolated struct TmuxRemoteSessionBackend: RemoteSessionBackend {
    let metadata = RemoteSessionBackendMetadata(
        identifier: .tmux,
        displayName: "tmux",
        installation: .automatic
    )

    private let tmux: RemoteTmuxManager

    init(tmux: RemoteTmuxManager) {
        self.tmux = tmux
    }

    nonisolated func isManagedIdentifier(
        _ identifier: RemoteSessionIdentifier,
        deviceID: String
    ) -> Bool {
        RemoteSessionManagedIdentifierPolicy.isManagedIdentifier(
            identifier,
            deviceID: deviceID
        ) || RemoteSessionManagedIdentifierPolicy.isLegacyTmuxIdentifier(
            identifier,
            deviceID: deviceID
        )
    }

    func availability(using client: SSHClient) async -> RemoteSessionAvailability {
        switch await tmux.tmuxAvailability(using: client) {
        case .unsupported:
            return .unsupportedEnvironment
        case .confirmedMissing:
            return .confirmedMissing
        case .indeterminate(let failure):
            return .indeterminate(Self.map(failure))
        case .available(let backend):
            guard let probe = makeProbe(from: backend) else {
                return .indeterminate(.invalidResponse)
            }
            return .available(probe)
        }
    }

    func listSessions(
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        let backend = try tmuxBackend(from: runtime)
        let sessions = try await tmux.listSessions(using: client, backend: backend)
        guard sessions.count <= 512 else { throw SSHError.outputLimitExceeded }
        return try sessions.map { session in
            RemoteSessionDescriptor(
                id: try RemoteSessionIdentifier(
                    backendIdentifier: .tmux,
                    validating: session.name
                ),
                attachedClientCount: max(0, session.attachedClients),
                containerCount: max(0, session.windowCount),
                cleanupDisposition: RemoteSessionCleanupDisposition(
                    attachedClientCount: max(0, session.attachedClients)
                )
            )
        }
    }

    func prepareManagedSession(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        runtime: RemoteSessionRuntime
    ) async {
        guard let backend = try? tmuxBackend(from: runtime) else { return }
        await tmux.prepareConfig(
            using: client,
            terminalType: terminalType,
            themeStyle: themeStyle,
            backend: backend
        )
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionBackendLaunchPlan {
        let backend = try tmuxBackend(from: runtime)
        let sessionName = request.attachment.identifier.rawValue
        let command: String
        switch request.mode {
        case .attachOrCreate:
            guard request.attachment.ownership == .managed else {
                throw SSHError.unknown("External tmux sessions cannot be created by VVTerm")
            }
            command = RemoteTmuxCommandBuilder.attachCommand(
                themeStyle: request.themeStyle,
                sessionName: sessionName,
                workingDirectory: request.workingDirectory,
                backend: backend,
                lifecycleEnvelope: request.lifecycleEnvelope,
                transport: request.transport
            )
        case .attachExisting:
            command = RemoteTmuxCommandBuilder.attachExistingCommand(
                themeStyle: request.themeStyle,
                sessionName: sessionName,
                ownership: request.attachment.ownership,
                backend: backend,
                lifecycleEnvelope: request.lifecycleEnvelope,
                transport: request.transport
            )
        }

        let markerID = UUID().uuidString
        let existsMarker = "__VVTERM_SESSION_EXISTS_\(markerID)__"
        let missingMarker = "__VVTERM_SESSION_MISSING_\(markerID)__"
        return RemoteSessionBackendLaunchPlan(
            command: command,
            presenceProbe: RemoteSessionPresenceProbe(
                command: RemoteTmuxCommandBuilder.sessionPresenceProbeCommand(
                    sessionName: sessionName,
                    backend: backend,
                    existsMarker: existsMarker,
                    missingMarker: missingMarker
                ),
                existsMarker: existsMarker,
                missingMarker: missingMarker
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
        guard attachment.identifier.backendIdentifier == .tmux,
              let backend = await tmux.tmuxInstallBackend(using: client) else {
            return nil
        }
        return RemoteTmuxCommandBuilder.installAndAttachScript(
            themeStyle: themeStyle,
            sessionName: attachment.identifier.rawValue,
            workingDirectory: workingDirectory,
            terminalType: terminalType,
            backend: backend,
            attachAfterInstall: attachAfterInstall
        )
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {
        guard let backend = try? tmuxBackend(from: runtime) else { return }
        await tmux.killSession(
            named: identifier.rawValue,
            using: client,
            backend: backend
        )
    }

    func cleanupLegacySessions(
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {
        guard let backend = try? tmuxBackend(from: runtime) else { return }
        await tmux.cleanupLegacySessions(using: client, backend: backend)
    }

    func currentWorkingDirectory(
        for identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async -> String? {
        guard let backend = try? tmuxBackend(from: runtime) else { return nil }
        return await tmux.currentPath(
            sessionName: identifier.rawValue,
            using: client,
            backend: backend
        )
    }

    private func makeProbe(from backend: RemoteTmuxBackend) -> RemoteSessionProbe? {
        guard let executable = try? RemoteSessionExecutable(validating: backend.executablePath) else {
            return nil
        }
        let variant: String
        let shellFamily: RemoteShellFamily
        let shellExecutable: String?
        switch backend.variant {
        case .unixTmux:
            variant = "unix-tmux"
            shellFamily = .posix
            shellExecutable = nil
        case .windowsPsmux(let family, let executable):
            variant = "windows-psmux"
            shellFamily = family
            shellExecutable = executable
        }
        return RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: executable,
            implementationVariant: variant,
            rawVersion: backend.rawVersion,
            semanticVersion: RemoteSessionSemanticVersion(backend.rawVersion),
            shellFamily: shellFamily,
            shellExecutable: shellExecutable
        )
    }

    private func tmuxBackend(from runtime: RemoteSessionRuntime) throws -> RemoteTmuxBackend {
        let probe = runtime.probe
        guard probe.backendIdentifier == .tmux else {
            throw SSHError.unknown("Remote session backend mismatch")
        }
        switch probe.implementationVariant {
        case "unix-tmux":
            return .unixTmux(
                executablePath: probe.executable.path,
                rawVersion: probe.rawVersion
            )
        case "windows-psmux":
            return .windowsPsmux(
                commandName: probe.executable.path,
                shellFamily: probe.shellFamily,
                powerShellExecutable: probe.shellExecutable,
                executablePath: probe.executable.path,
                rawVersion: probe.rawVersion
            )
        default:
            throw SSHError.unknown("Unsupported tmux implementation variant")
        }
    }

    private static func map(_ failure: RemoteTmuxProbeFailure) -> RemoteSessionProbeFailure {
        switch failure {
        case .cancelled: .cancelled
        case .timeout: .timeout
        case .disconnected: .disconnected
        case .transport(let message): .transport(message)
        case .channelOpenFailed: .channelOpenFailed
        case .shellRequestFailed: .shellRequestFailed
        case .invalidResponse: .invalidResponse
        case .commandFailed(let message): .commandFailed(message)
        }
    }
}
