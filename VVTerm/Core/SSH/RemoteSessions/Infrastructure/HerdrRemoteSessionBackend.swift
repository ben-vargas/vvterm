import Foundation

nonisolated struct HerdrRemoteSessionBackend: RemoteSessionBackend {
    static let minimumVersion07 = RemoteSessionSemanticVersion(
        major: 0,
        minor: 7,
        patch: 5
    )
    static let minimumVersion08 = RemoteSessionSemanticVersion(
        major: 0,
        minor: 8,
        patch: 2
    )

    let metadata = RemoteSessionBackendMetadata(
        identifier: .herdr,
        displayName: "Herdr",
        installation: .documentation(URL(string: "https://herdr.dev/docs/install/")!),
        managedStartupCommandSupport: .unsupported
    )

    func availability(using client: SSHClient) async -> RemoteSessionAvailability {
        let environment = await client.remoteEnvironment()
        return await availability(in: environment) { command in
            try await client.execute(
                command,
                timeout: .seconds(8),
                maxOutputBytes: HerdrRemoteSessionParser.maximumProbeOutputBytes
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
                HerdrRemoteSessionCommandBuilder.availabilityProbeCommand()
            )
            try Task.checkCancellation()
            let result = HerdrRemoteSessionParser.parseProbe(output)
            let reportsMissing = output.contains(
                HerdrRemoteSessionCommandBuilder.missingMarker
            )
            switch (result, reportsMissing) {
            case (nil, true):
                return .confirmedMissing
            case (let result?, false):
                let probe = RemoteSessionProbe(
                    backendIdentifier: .herdr,
                    executable: result.executable,
                    implementationVariant: Self.implementationVariant(
                        for: result.semanticVersion
                    ),
                    rawVersion: result.rawVersion,
                    semanticVersion: result.semanticVersion,
                    shellFamily: .posix,
                    shellExecutable: environment.shellProfile.executableName
                )
                return Self.supportedSeries(for: result.semanticVersion) == nil
                    ? .incompatible(probe)
                    : .available(probe)
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
            HerdrRemoteSessionCommandBuilder.listCommand(runtime: runtime),
            timeout: .seconds(12),
            maxOutputBytes: HerdrRemoteSessionParser.maximumOutputBytes
        )
        try Task.checkCancellation()
        return try HerdrRemoteSessionParser.parseSessionList(output, scope: scope)
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionBackendLaunchPlan {
        try requireSupported(runtime)
        guard request.attachment.identifier.backendIdentifier == .herdr else {
            throw SSHError.unknown("Remote session backend mismatch")
        }
        return RemoteSessionBackendLaunchPlan(
            command: try HerdrRemoteSessionCommandBuilder.launchCommand(
                request: request,
                runtime: runtime
            ),
            presenceProbe: try HerdrRemoteSessionCommandBuilder.presenceProbe(
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
    ) async throws {
        guard identifier.backendIdentifier == .herdr else { throw SSHError.unknown("Remote session backend mismatch") }
        try requireSupported(runtime)
        let stop = try HerdrRemoteSessionCommandBuilder.stopCommand(
            identifier: identifier,
            runtime: runtime
        )
        let delete =
            identifier.rawValue == "default"
            ? nil
            : try HerdrRemoteSessionCommandBuilder.deleteCommand(
                identifier: identifier,
                runtime: runtime
            )

        try await client.executeChecked(
            stop,
            timeout: .seconds(18),
            maxOutputBytes: HerdrRemoteSessionParser.maximumMutationOutputBytes
        )
        try Task.checkCancellation()
        guard let delete else { return }
        try await client.executeChecked(
            delete,
            timeout: .seconds(8),
            maxOutputBytes: HerdrRemoteSessionParser.maximumMutationOutputBytes
        )
    }

    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async -> String? {
        guard attachment.identifier.backendIdentifier == .herdr else { return nil }
        do {
            try requireSupported(runtime)
            let command = try HerdrRemoteSessionCommandBuilder.currentPaneCommand(
                identifier: attachment.identifier,
                runtime: runtime
            )
            let output = try await client.execute(
                command,
                timeout: .seconds(8),
                maxOutputBytes: HerdrRemoteSessionParser.maximumOutputBytes,
                timeoutScope: .command
            )
            guard !Task.isCancelled else { return nil }
            return HerdrRemoteSessionParser.parseWorkingDirectory(output)
        } catch {
            return nil
        }
    }

    private enum CLISeries: String {
        case version07 = "herdr-0.7"
        case version08 = "herdr-0.8"
    }

    private static func supportedSeries(
        for version: RemoteSessionSemanticVersion
    ) -> CLISeries? {
        guard version.major == 0 else { return nil }
        switch version.minor {
        case 7 where version.patch >= minimumVersion07.patch:
            return .version07
        case 8 where version.patch >= minimumVersion08.patch:
            return .version08
        default:
            return nil
        }
    }

    private static func implementationVariant(
        for version: RemoteSessionSemanticVersion
    ) -> String {
        switch (version.major, version.minor) {
        case (0, 7): CLISeries.version07.rawValue
        case (0, 8): CLISeries.version08.rawValue
        default: "herdr-unsupported"
        }
    }

    private func requireSupported(_ runtime: RemoteSessionRuntime) throws {
        let probe = runtime.probe
        guard probe.backendIdentifier == .herdr,
              probe.shellFamily == .posix,
              let version = probe.semanticVersion,
              let series = Self.supportedSeries(for: version),
              probe.implementationVariant == series.rawValue else {
            throw SSHError.unknown("Unsupported Herdr runtime")
        }
    }
}
