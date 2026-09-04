import Foundation

nonisolated struct ZellijRemoteSessionBackend: RemoteSessionBackend {
    static let supportedVersions: Set<RemoteSessionSemanticVersion> = [
        RemoteSessionSemanticVersion(major: 0, minor: 44, patch: 3),
        RemoteSessionSemanticVersion(major: 0, minor: 45, patch: 0)
    ]

    let metadata = RemoteSessionBackendMetadata(
        identifier: .zellij,
        displayName: "Zellij",
        installation: .documentation(
            URL(string: "https://zellij.dev/documentation/installation")!
        ),
        managedStartupCommandSupport: .supported
    )

    func availability(using client: SSHClient) async -> RemoteSessionAvailability {
        let environment = await client.remoteEnvironment()
        return await availability(in: environment) { command in
            try await client.execute(
                command,
                timeout: .seconds(8),
                maxOutputBytes: ZellijRemoteSessionParser.maximumProbeOutputBytes
            )
        }
    }

    func availability(
        in environment: RemoteEnvironment,
        execute: @escaping @Sendable (String) async throws -> String
    ) async -> RemoteSessionAvailability {
        guard environment.platform != .windows,
              environment.shellProfile.family == .posix else {
            return .unsupportedEnvironment
        }

        do {
            let output = try await execute(
                ZellijRemoteSessionCommandBuilder.availabilityProbeCommand()
            )
            try Task.checkCancellation()
            let result = ZellijRemoteSessionParser.parseProbe(output)
            let reportsMissing = output.contains(
                ZellijRemoteSessionCommandBuilder.missingMarker
            )
            switch (result, reportsMissing) {
            case (nil, true):
                return .confirmedMissing
            case (let result?, false):
                let probe = RemoteSessionProbe(
                    backendIdentifier: .zellij,
                    executable: result.executable,
                    implementationVariant: Self.implementationVariant(
                        for: result.semanticVersion
                    ),
                    rawVersion: result.rawVersion,
                    semanticVersion: result.semanticVersion,
                    shellFamily: .posix,
                    shellExecutable: environment.shellProfile.executableName
                )
                return Self.supportedVersions.contains(result.semanticVersion)
                    ? .available(probe)
                    : .incompatible(probe)
            case (nil, false), (.some, true):
                return .indeterminate(.invalidResponse)
            }
        } catch {
            return .indeterminate(.resolve(error))
        }
    }

    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        try requireSupported(runtime)
        let output = try await client.executeChecked(
            ZellijRemoteSessionCommandBuilder.listCommand(
                scope: scope,
                runtime: runtime
            ),
            timeout: .seconds(12),
            maxOutputBytes: ZellijRemoteSessionParser.maximumOutputBytes
        )
        try Task.checkCancellation()
        let sessions = try ZellijRemoteSessionParser.parseSessionList(output)
        switch scope {
        case .userVisible:
            guard sessions.allSatisfy({ $0.attachment.ownership == .external }) else {
                throw SSHError.unknown("Zellij returned invalid user session ownership")
            }
        case .managedCleanup:
            guard sessions.allSatisfy({ $0.attachment.ownership == .managed }) else {
                throw SSHError.unknown("Zellij returned invalid managed session ownership")
            }
        }
        return sessions
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionBackendLaunchPlan {
        try requireSupported(runtime)
        guard request.attachment.identifier.backendIdentifier == .zellij else {
            throw SSHError.unknown("Remote session backend mismatch")
        }
        return RemoteSessionBackendLaunchPlan(
            command: try ZellijRemoteSessionCommandBuilder.launchCommand(
                request: request,
                runtime: runtime
            ),
            presenceProbe: try ZellijRemoteSessionCommandBuilder.presenceProbe(
                attachment: request.attachment,
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
    ) async throws {
        guard identifier.backendIdentifier == .zellij else { throw SSHError.unknown("Remote session backend mismatch") }
        try requireSupported(runtime)
        let command = try ZellijRemoteSessionCommandBuilder.killManagedCommand(
            identifier: identifier,
            runtime: runtime
        )
        try await client.executeChecked(
            command,
            timeout: .seconds(18),
            maxOutputBytes: ZellijRemoteSessionParser.maximumMutationOutputBytes
        )
    }

    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async -> String? {
        guard attachment.identifier.backendIdentifier == .zellij else { return nil }
        do {
            try requireSupported(runtime)
            let output = try await client.execute(
                ZellijRemoteSessionCommandBuilder.listPanesCommand(
                    attachment: attachment,
                    runtime: runtime
                ),
                timeout: .seconds(8),
                maxOutputBytes: ZellijRemoteSessionParser.maximumOutputBytes,
                timeoutScope: .command
            )
            guard !Task.isCancelled else { return nil }
            return ZellijRemoteSessionParser.parseWorkingDirectory(output)
        } catch {
            return nil
        }
    }

    private static func implementationVariant(
        for version: RemoteSessionSemanticVersion
    ) -> String {
        "zellij-\(version.major).\(version.minor)"
    }

    private func requireSupported(_ runtime: RemoteSessionRuntime) throws {
        let probe = runtime.probe
        guard probe.backendIdentifier == .zellij,
              probe.shellFamily == .posix,
              let version = probe.semanticVersion,
              Self.supportedVersions.contains(version),
              probe.implementationVariant == Self.implementationVariant(for: version) else {
            throw SSHError.unknown("Unsupported Zellij runtime")
        }
    }
}
