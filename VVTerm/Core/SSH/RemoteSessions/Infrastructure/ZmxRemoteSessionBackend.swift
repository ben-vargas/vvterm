import Foundation

nonisolated struct ZmxRemoteSessionBackend: RemoteSessionBackend {
    static let minimumVersion = RemoteSessionSemanticVersion(
        major: 0,
        minor: 7,
        patch: 0
    )

    let metadata = RemoteSessionBackendMetadata(
        identifier: .zmx,
        displayName: "zmx",
        installation: .documentation(URL(string: "https://zmx.sh")!)
    )

    func availability(using client: SSHClient) async -> RemoteSessionAvailability {
        let environment = await client.remoteEnvironment()
        guard environment.platform != .windows,
              environment.shellProfile.family == .posix else {
            return .unsupportedEnvironment
        }

        do {
            let output = try await client.execute(
                ZmxRemoteSessionCommandBuilder.availabilityProbeCommand(),
                timeout: .seconds(8),
                maxOutputBytes: 8 * 1_024
            )
            try Task.checkCancellation()
            if output.contains(ZmxRemoteSessionCommandBuilder.missingMarker) {
                return .confirmedMissing
            }
            guard let result = ZmxRemoteSessionParser.parseProbe(output) else {
                return .indeterminate(.invalidResponse)
            }
            let probe = RemoteSessionProbe(
                backendIdentifier: .zmx,
                executable: result.executable,
                implementationVariant: "zmx",
                rawVersion: result.rawVersion,
                semanticVersion: result.semanticVersion,
                shellFamily: .posix,
                shellExecutable: environment.shellProfile.executableName
            )
            return result.semanticVersion >= Self.minimumVersion
                ? .available(probe)
                : .incompatible(probe)
        } catch {
            return .indeterminate(.resolve(error))
        }
    }

    func listSessions(
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        try requireSupported(runtime)
        let output = try await client.execute(
            ZmxRemoteSessionCommandBuilder.listCommand(runtime: runtime),
            timeout: .seconds(12),
            maxOutputBytes: ZmxRemoteSessionParser.maximumOutputBytes
        )
        return try ZmxRemoteSessionParser.parseSessionList(output)
    }

    func prepareManagedSession(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        runtime: RemoteSessionRuntime
    ) async {
        // zmx does not use a VVTerm-generated configuration file.
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionBackendLaunchPlan {
        try requireSupported(runtime)
        guard request.attachment.identifier.backendIdentifier == .zmx else {
            throw SSHError.unknown("Remote session backend mismatch")
        }
        return RemoteSessionBackendLaunchPlan(
            command: try ZmxRemoteSessionCommandBuilder.launchCommand(
                request: request,
                runtime: runtime
            ),
            presenceProbe: try ZmxRemoteSessionCommandBuilder.presenceProbe(
                identifier: request.attachment.identifier,
                runtime: runtime
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
    ) async {
        guard identifier.backendIdentifier == .zmx else { return }
        let command: String
        do {
            try requireSupported(runtime)
            command = try ZmxRemoteSessionCommandBuilder.killCommand(
                identifier: identifier,
                runtime: runtime
            )
        } catch {
            return
        }
        _ = try? await client.execute(
            command,
            timeout: .seconds(10),
            maxOutputBytes: 8 * 1_024
        )
    }

    func cleanupLegacySessions(
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {}

    func currentWorkingDirectory(
        for identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async -> String? {
        guard identifier.backendIdentifier == .zmx else { return nil }
        do {
            try requireSupported(runtime)
            let output = try await client.execute(
                ZmxRemoteSessionCommandBuilder.listCommand(runtime: runtime),
                timeout: .seconds(8),
                maxOutputBytes: ZmxRemoteSessionParser.maximumOutputBytes
            )
            return ZmxRemoteSessionParser.parseWorkingDirectory(
                for: identifier,
                in: output
            )
        } catch {
            return nil
        }
    }

    private func requireSupported(_ runtime: RemoteSessionRuntime) throws {
        let probe = runtime.probe
        guard probe.backendIdentifier == .zmx,
              probe.implementationVariant == "zmx",
              probe.shellFamily == .posix,
              let version = probe.semanticVersion,
              version >= Self.minimumVersion else {
            throw SSHError.unknown("Unsupported zmx runtime")
        }
    }

}
