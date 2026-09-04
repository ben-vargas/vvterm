import Foundation
import os.log

actor RemoteTmuxManager {
    private let availabilityTimeout: Duration = .seconds(8)
    private let listTimeout: Duration = .seconds(12)
    private let killTimeout: Duration = .seconds(10)
    private let pathTimeout: Duration = .seconds(10)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "Tmux"
    )

    init() {}

    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability {
        let trace = await client.startupTrace
        let token = trace?.begin(.sessionProbe)
        defer { if let token { trace?.end(token) } }
        let probeId = UUID().uuidString
        let startedAt = ContinuousClock.now
        logger.info("Starting tmux availability probe \(probeId, privacy: .public)")
        let environment = await client.remoteEnvironment()
        guard !Task.isCancelled else {
            return .indeterminate(.cancelled)
        }
        let result = await tmuxAvailability(in: environment) { command, timeout in
            try await client.execute(command, timeout: timeout)
        }
        let elapsed = startedAt.duration(to: ContinuousClock.now)
        logger.info(
            "Tmux availability probe \(probeId, privacy: .public) resolved \(result.logDescription, privacy: .public) after \(String(describing: elapsed), privacy: .public)"
        )
        return result
    }

    func tmuxAvailability(
        in environment: RemoteEnvironment,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async -> RemoteTmuxAvailability {
        guard !Task.isCancelled else { return .indeterminate(.cancelled) }
        guard environment.supportsTmuxRuntime else { return .unsupported }

        if environment.platform == .windows {
            return await windowsPsmuxAvailability(for: environment, execute: execute)
        }

        let okMarker = "__VVTERM_TMUX_OK__"
        let command = RemoteTmuxCommandBuilder.tmuxAvailabilityProbeCommand(okMarker: okMarker)
        do {
            let output = try await execute(command, availabilityTimeout)
            try Task.checkCancellation()
            let classification = RemoteTmuxParser.classifyAvailabilityOutput(
                output,
                availableMarker: okMarker,
                missingMarker: "__VVTERM_TMUX_NO__",
                backend: .unixTmux
            )
            guard case .available = classification else { return classification }
            guard let backend = RemoteTmuxParser.resolvedBackend(
                from: output,
                variant: .unixTmux
            ) else {
                return .indeterminate(.invalidResponse)
            }
            return RemoteTmuxParser.classifyAvailabilityOutput(
                output,
                availableMarker: okMarker,
                missingMarker: "__VVTERM_TMUX_NO__",
                backend: backend
            )
        } catch {
            return .indeterminate(.resolve(error))
        }
    }

    private func availableBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        await tmuxAvailability(using: client).backend
    }

    private func resolveBackend(
        _ explicitBackend: RemoteTmuxBackend?,
        using client: SSHClient
    ) async -> RemoteTmuxBackend? {
        if let explicitBackend {
            return explicitBackend
        }
        return await availableBackend(using: client)
    }

    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        let environment = await client.remoteEnvironment()
        guard environment.supportsTmuxRuntime else { return nil }

        if environment.platform == .windows {
            let powerShellExecutable = RemoteTmuxCommandBuilder.windowsPowerShellExecutable(
                for: environment
            )
            if environment.shellProfile.family == .cmd, powerShellExecutable == nil {
                return nil
            }
            return .windowsPsmux(
                commandName: "psmux",
                shellFamily: environment.shellProfile.family,
                powerShellExecutable: powerShellExecutable
            )
        }

        return .unixTmux
    }

    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend,
        requireSuccessfulExit: Bool = false
    ) async throws -> [RemoteTmuxSession] {
        let trace = await client.startupTrace
        let token = trace?.begin(.sessionList)
        do {
            let sessions = try await listSessions(backend: backend) { command, timeout in
                if requireSuccessfulExit {
                    return try await client.executeChecked(command, timeout: timeout)
                }
                return try await client.execute(command, timeout: timeout, timeoutScope: .command)
            }
            if let token { trace?.end(token) }
            return sessions
        } catch {
            if let token { trace?.end(token, outcome: "failed") }
            throw error
        }
    }

    func listSessions(
        backend: RemoteTmuxBackend,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async throws -> [RemoteTmuxSession] {
        let candidates = RemoteTmuxCommandBuilder.listSessionCommands(backend: backend)
        var lastError: Error?

        for (index, command) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let output = try await execute(command, listTimeout)
                try Task.checkCancellation()
                let lines = output.split(whereSeparator: \.isNewline)
                let reportedSuccess = !backend.isWindows || lines.contains {
                    $0.trimmingCharacters(in: .whitespaces) == RemoteTmuxCommandBuilder.sessionListSuccessMarker
                }
                let confirmedEmpty = backend.isWindows
                    && lines.map { $0.trimmingCharacters(in: .whitespaces) }
                        == [RemoteTmuxCommandBuilder.sessionListSuccessMarker]
                let sessions = RemoteTmuxParser.parseSessionListOutput(
                    lines.filter { $0 != RemoteTmuxCommandBuilder.sessionListSuccessMarker }
                        .joined(separator: "\n"),
                    allowLegacy: index == candidates.count - 1
                )

                if reportedSuccess && (!sessions.isEmpty || confirmedEmpty) {
                    return sessions
                }
                if !backend.isWindows && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return []
                }
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }

        throw lastError ?? SSHError.unknown("Unable to list tmux sessions")
    }

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async throws {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        try await client.write(data, to: shellId)
    }

    func killSession(
        named sessionName: String,
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async throws {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { throw SSHError.notConnected }
        let command = RemoteTmuxCommandBuilder.killSessionCommand(
            named: sessionName,
            backend: backend
        )
        try await client.executeChecked(command, timeout: killTimeout)
    }

    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async -> String? {
        let trace = await client.startupTrace
        let token = trace?.begin(.sessionWorkingDirectory)
        defer { if let token { trace?.end(token) } }
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return nil }
        let command = RemoteTmuxCommandBuilder.currentPathCommand(
            sessionName: sessionName,
            backend: backend
        )
        guard let output = try? await client.execute(command, timeout: pathTimeout, timeoutScope: .command) else { return nil }
        let trimmed = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func windowsPsmuxAvailability(
        for environment: RemoteEnvironment,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async -> RemoteTmuxAvailability {
        let shellFamily = environment.shellProfile.family
        let powerShellExecutable = RemoteTmuxCommandBuilder.windowsPowerShellExecutable(
            for: environment
        )
        guard shellFamily == .powershell
                || (shellFamily == .cmd && powerShellExecutable != nil) else {
            return .unsupported
        }
        var firstIndeterminateFailure: RemoteTmuxProbeFailure?

        for (commandName, requirePsmuxExtension) in [
            ("psmux", false),
            ("pmux", false),
            ("tmux", true)
        ] {
            let backend = RemoteTmuxBackend.windowsPsmux(
                commandName: commandName,
                shellFamily: shellFamily,
                powerShellExecutable: powerShellExecutable
            )
            do {
                let output = try await execute(
                    RemoteTmuxCommandBuilder.windowsPsmuxAvailabilityProbeCommand(
                        commandName: commandName,
                        backend: backend,
                        requirePsmuxExtension: requirePsmuxExtension
                    ),
                    availabilityTimeout
                )
                try Task.checkCancellation()
                let classification = RemoteTmuxParser.classifyAvailabilityOutput(
                    output,
                    availableMarker: "__VVTERM_TMUX_OK__:\(commandName)",
                    missingMarker: "__VVTERM_TMUX_NO__:\(commandName)",
                    backend: backend
                )
                guard case .available = classification else {
                    switch classification {
                    case .indeterminate(let failure):
                        firstIndeterminateFailure = firstIndeterminateFailure ?? failure
                    case .confirmedMissing:
                        break
                    case .unsupported:
                        assertionFailure("A supported Windows tmux probe resolved as unsupported")
                    case .available:
                        break
                    }
                    continue
                }
                let variant = RemoteTmuxBackend.Variant.windowsPsmux(
                    shellFamily: shellFamily,
                    powerShellExecutable: powerShellExecutable
                )
                guard let resolvedBackend = RemoteTmuxParser.resolvedBackend(
                    from: output,
                    variant: variant
                ) else {
                    firstIndeterminateFailure = firstIndeterminateFailure ?? .invalidResponse
                    continue
                }
                let resolution = RemoteTmuxParser.classifyAvailabilityOutput(
                    output,
                    availableMarker: "__VVTERM_TMUX_OK__:\(commandName)",
                    missingMarker: "__VVTERM_TMUX_NO__:\(commandName)",
                    backend: resolvedBackend
                )
                switch resolution {
                case .available:
                    return resolution
                case .indeterminate(let failure):
                    firstIndeterminateFailure = firstIndeterminateFailure ?? failure
                case .confirmedMissing:
                    break
                case .unsupported:
                    assertionFailure("A supported Windows tmux probe resolved as unsupported")
                }
            } catch {
                firstIndeterminateFailure = firstIndeterminateFailure ?? .resolve(error)
            }
        }

        if let firstIndeterminateFailure {
            return .indeterminate(firstIndeterminateFailure)
        }
        return .confirmedMissing
    }

}
