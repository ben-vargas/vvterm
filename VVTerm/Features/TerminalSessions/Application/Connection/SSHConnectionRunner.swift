import Foundation
import os.log

nonisolated struct SSHConnectionInitialTerminalState: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let pixelSize: TerminalPixelSize?
}

nonisolated struct SSHConnectionRestoredShell: Sendable {
    let shell: ShellHandle
    let remoteSessionLifecycle: RemoteSessionLifecycleContext?
    let startupActionReplayPending: Bool
}

nonisolated struct SSHConnectionRunnerTransport: Sendable {
    let connect: @Sendable (_ server: Server, _ credentials: ServerCredentials) async throws -> Void
    let startShell: @Sendable (
        _ columns: Int,
        _ rows: Int,
        _ pixelSize: TerminalPixelSize?,
        _ startupCommand: String?,
        _ mayExecuteUserStartupAction: Bool,
        _ shellProfile: RemoteShellProfile?
    ) async throws -> ShellHandle
    let disconnect: @Sendable () async -> Void
    let closeShell: @Sendable (_ shellId: UUID) async -> Void
    let execute: @Sendable (_ command: String, _ timeout: Duration?) async throws -> String

    static func live(client: SSHClient) -> Self {
        Self(
            connect: { server, credentials in
                _ = try await client.connect(
                    to: server, credentials: credentials,
                    preferredPlatform: server.detectedSystemIdentity?.kind == .windows ? .windows : nil
                )
            },
            startShell: { columns, rows, pixelSize, startupCommand, mayExecuteUserStartupAction, shellProfile in
                try await client.startShell(
                    cols: columns,
                    rows: rows,
                    pixelSize: pixelSize,
                    startupCommand: startupCommand,
                    mayExecuteUserStartupAction: mayExecuteUserStartupAction,
                    startupShellProfile: shellProfile
                )
            },
            disconnect: {
                await client.disconnect()
            },
            closeShell: { shellId in
                await client.closeShell(shellId)
            },
            execute: { command, timeout in
                try await client.execute(command, timeout: timeout)
            }
        )
    }
}

nonisolated enum SSHConnectionRunner {
    static func run(
        server: Server,
        credentials: ServerCredentials,
        transport: SSHConnectionRunnerTransport,
        initialTerminalState: SSHConnectionInitialTerminalState,
        logger: Logger,
        shouldContinueConnection: @MainActor @escaping @Sendable () -> Bool,
        onAttempt: @MainActor @escaping @Sendable (_ attempt: Int) -> Void,
        startupPlan: @MainActor @escaping @Sendable () async throws -> TerminalShellStartupPlan,
        setStartupActionReplayGuard: @MainActor @escaping @Sendable (
            _ isPending: Bool
        ) -> Void = { _ in },
        onRemoteSessionAttached: @MainActor @escaping @Sendable () -> Void = {},
        restoreMoshShell: @MainActor @escaping @Sendable (
            _ cols: Int,
            _ rows: Int
        ) async -> SSHConnectionRestoredShell?,
        registerShell: @MainActor @escaping @Sendable (
            _ shell: ShellHandle,
            _ startupPlan: TerminalShellStartupPlan
        ) async -> Bool,
        onTitleChange: @MainActor @escaping @Sendable (_ title: String) -> Void,
        writeOutput: @MainActor @escaping @Sendable (_ data: Data) async -> Bool,
        shouldResetClient: @escaping @Sendable (_ error: SSHError) async -> Bool,
        onProcessExit: @MainActor @escaping @Sendable (
            _ shellId: UUID,
            _ reason: TerminalShellEndReason
        ) -> Void,
        onFailure: @MainActor @escaping @Sendable (_ error: Error) async -> Void
    ) async {
        guard credentials.isAuthorized(for: server) else {
            await onFailure(KeychainError.credentialServerMismatch)
            return
        }

        let maxAttempts = 3
        var lastError: Error?
        var titleParser = TerminalTitleSequenceParser()

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            guard await shouldContinueConnection() else { return }
            await onAttempt(attempt)

            do {
                logger.info(
                    "Connecting to \(server.host, privacy: .private(mask: .hash))... (attempt \(attempt))"
                )
                let cols = initialTerminalState.columns
                let rows = initialTerminalState.rows
                let pixelSize = initialTerminalState.pixelSize

                let shell: ShellHandle
                let startup: TerminalShellStartupPlan
                if let restored = await restoreMoshShell(cols, rows) {
                    shell = restored.shell
                    startup = TerminalShellStartupPlan(
                        command: nil,
                        remoteSessionLifecycle: restored.remoteSessionLifecycle,
                        mayExecuteUserStartupAction: restored
                            .startupActionReplayPending
                    )
                    logger.info("Restored existing Mosh protocol session")
                } else {
                    try await transport.connect(server, credentials)
                    guard !Task.isCancelled else { return }
                    guard await shouldContinueConnection() else { return }

                    let freshStartup = try await startupPlan()
                    guard !Task.isCancelled else { return }
                    guard await shouldContinueConnection() else { return }
                    if freshStartup.mayExecuteUserStartupAction {
                        await setStartupActionReplayGuard(true)
                    }
                    do {
                        shell = try await transport.startShell(
                            cols,
                            rows,
                            pixelSize,
                            freshStartup.command,
                            freshStartup.mayExecuteUserStartupAction,
                            freshStartup.shellProfile
                        )
                    } catch {
                        if error is SSHShellPreparationError {
                            if freshStartup.mayExecuteUserStartupAction {
                                await setStartupActionReplayGuard(false)
                            }
                            throw error
                        }
                        if let sshError = error as? SSHError,
                           sshError.provesStartupCommandWasNotDispatched {
                            if freshStartup.mayExecuteUserStartupAction {
                                await setStartupActionReplayGuard(false)
                            }
                            throw sshError
                        }
                        if error is CancellationError {
                            if freshStartup.mayExecuteUserStartupAction {
                                await setStartupActionReplayGuard(false)
                            }
                            throw CancellationError()
                        }
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        if let sshError = error as? SSHError,
                           case .processRequestOutcomeUnknown = sshError {
                            if freshStartup.mayExecuteUserStartupAction {
                                throw sshError
                            }
                            throw SSHError.shellRequestFailed
                        }
                        if freshStartup.mayExecuteUserStartupAction {
                            throw SSHError.startupCommandMayHaveRun
                        }
                        throw error
                    }
                    startup = freshStartup
                }

                guard !Task.isCancelled else {
                    await transport.closeShell(shell.id)
                    return
                }
                guard await shouldContinueConnection() else {
                    await transport.closeShell(shell.id)
                    return
                }
                guard await registerShell(shell, startup) else { return }

                guard !Task.isCancelled else { return }
                var lifecycleParser = startup.remoteSessionLifecycle.map {
                    RemoteSessionLifecycleStreamParser(observation: $0.observation)
                }
                var lastLifecycleEvent: RemoteSessionEvent?
                for await data in shell.stream {
                    guard !Task.isCancelled else { break }
                    guard await shouldContinueConnection() else { break }
                    let visibleData: Data
                    if var parser = lifecycleParser {
                        let parsed = parser.consume(data)
                        lifecycleParser = parser
                        visibleData = parsed.output
                        if let event = parsed.events.last {
                            lastLifecycleEvent = event
                        }
                        if parsed.events.contains(.attached) {
                            await onRemoteSessionAttached()
                        }
                    } else {
                        visibleData = data
                    }

                    for title in titleParser.parse(visibleData) {
                        await onTitleChange(title)
                    }
                    let shouldContinue = await writeOutput(visibleData)
                    if !shouldContinue { break }
                }
                guard !Task.isCancelled else { return }
                guard await shouldContinueConnection() else { return }
                if var lifecycleParser {
                    let remaining = lifecycleParser.finish()
                    if !remaining.isEmpty {
                        _ = await writeOutput(remaining)
                    }
                }

                var sessionExists: Bool?
                if lastLifecycleEvent == nil || lastLifecycleEvent == .attached,
                   let presenceProbe = startup.remoteSessionLifecycle?
                    .observation.presenceProbe {
                    do {
                        let output = try await transport.execute(
                            presenceProbe.command,
                            .seconds(8)
                        )
                        sessionExists = presenceProbe.sessionExists(in: output)
                    } catch {
                        logger.warning(
                            "Unable to verify remote session after shell exit: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                let endReason: TerminalShellEndReason =
                    startup.mayExecuteStandaloneUserStartupAction
                    ? .standaloneStartupActionCompleted
                    : TerminalShellEndReason.resolve(
                        lifecycle: startup.remoteSessionLifecycle,
                        event: lastLifecycleEvent,
                        sessionExists: sessionExists
                    )
                logger.info("SSH shell ended: \(String(describing: endReason), privacy: .public)")
                await onProcessExit(shell.id, endReason)
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard await shouldContinueConnection() else { return }
                lastError = error
                logger.error("SSH connection failed (attempt \(attempt)): \(error.localizedDescription)")

                if !TerminalConnectionFailure.transport(error).allowsAutomaticReconnectRetry { break }

                if attempt < maxAttempts, let sshError = error as? SSHError {
                    let shouldReset = await shouldResetClient(sshError)
                    guard !Task.isCancelled else { return }
                    guard await shouldContinueConnection() else { return }
                    if shouldReset {
                        logger.warning("Resetting SSH client before retrying connection")
                        await transport.disconnect()
                        guard !Task.isCancelled else { return }
                        guard await shouldContinueConnection() else { return }
                    }
                }

                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
        }

        if let lastError {
            guard await shouldContinueConnection() else { return }
            await onFailure(lastError)
        }
    }
}
