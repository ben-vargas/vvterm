import Foundation
import os.log

@MainActor
final class TerminalPaneSSHCoordinator {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let sshClient: SSHClient
    let tabManager: TerminalTabManager

    private let richPasteRuntime: TerminalRichPasteRuntime
    private let transportWriteQueue = TerminalTransportWriteQueue()
    private var lastTerminalSize: (cols: Int, rows: Int, pixels: TerminalPixelSize?) = (0, 0, nil)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHPane")

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        tabManager: TerminalTabManager,
        richPasteUIModel: TerminalRichPasteUIModel
    ) {
        self.paneId = paneId
        self.server = server
        self.credentials = credentials
        self.sshClient = sshClient
        self.tabManager = tabManager
        self.richPasteRuntime = .terminalPane(
            paneId: paneId,
            sshClient: sshClient,
            tabManager: tabManager,
            uiModel: richPasteUIModel
        )
    }

    @MainActor
    func installRichPasteInterception(on terminal: GhosttyTerminalView) {
        richPasteRuntime.install(on: terminal)
    }

    @MainActor
    func sendToSSH(_ data: Data) {
        guard let route = Self.sshRoute(
            paneId: paneId,
            tabManager: tabManager
        ) else {
            return
        }
        let logger = logger
        transportWriteQueue.enqueue {
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func handleResize(cols: Int, rows: Int, pixelSize: TerminalPixelSize?) {
        guard cols > 0 && rows > 0 else { return }
        guard let route = Self.sshRoute(
            paneId: paneId,
            tabManager: tabManager
        ) else { return }
        guard cols != lastTerminalSize.cols
                || rows != lastTerminalSize.rows
                || pixelSize != lastTerminalSize.pixels else { return }
        lastTerminalSize = (cols, rows, pixelSize)

        Task(priority: .userInitiated) { [logger] in
            do {
                try await route.client.resize(
                    cols: cols,
                    rows: rows,
                    pixelSize: pixelSize,
                    for: route.shellId
                )
            } catch {
                logger.warning("Failed to resize PTY: \(error.localizedDescription)")
            }
        }
    }

    private static func sshRoute(
        paneId: UUID,
        tabManager: TerminalTabManager
    ) -> (client: SSHClient, shellId: UUID)? {
        tabManager.activeSSHRoute(for: paneId)
    }

    func startSSHConnection(terminal: GhosttyTerminalView) {
        let paneId = self.paneId
        if tabManager.activeSSHRoute(for: paneId) != nil {
            tabManager.updatePaneState(paneId, connectionState: .connected)
            logger.debug("Reusing existing shell for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        let sshClient = self.sshClient
        let server = self.server
        let credentials = self.credentials
        let logger = self.logger
        let transport = SSHConnectionRunnerTransport.live(client: sshClient)
        let initialTerminalState = Self.initialTerminalState(for: terminal)
        let hasEstablishedConnection = tabManager.paneState(for: paneId)?.hasEstablishedConnection == true
        guard tabManager.startSSHConnectionTask(
            for: paneId,
            server: server,
            client: sshClient,
            operation: { [weak terminal] context in
                await Self.runConnection(
                    server: server,
                    credentials: credentials,
                    sshClient: sshClient,
                    transport: transport,
                    initialTerminalState: initialTerminalState,
                    context: context,
                    hasEstablishedConnection: hasEstablishedConnection,
                    logger: logger,
                    writeOutput: { [weak terminal] data in
                        guard context.isCurrent(), let terminal else { return false }
                        terminal.feedData(data)
                        return true
                    },
                    reportFailure: { [weak terminal] error in
                        guard context.isCurrent() else { return }
                        let message = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                        if let data = message.data(using: .utf8) {
                            terminal?.feedData(data)
                        }
                    }
                )
            }
        ) else {
            if tabManager.activeSSHRoute(for: paneId) != nil {
                tabManager.updatePaneState(paneId, connectionState: .connected)
            }
            logger.debug("Shell start already in progress for pane \(paneId.uuidString, privacy: .public)")
            return
        }
    }

    private static func runConnection(
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        transport: SSHConnectionRunnerTransport,
        initialTerminalState: SSHConnectionInitialTerminalState,
        context: TerminalSSHConnectionContext,
        hasEstablishedConnection: Bool,
        logger: Logger,
        writeOutput: @MainActor @escaping @Sendable (Data) -> Bool,
        reportFailure: @MainActor @escaping @Sendable (Error) -> Void
    ) async {
        await SSHConnectionRunner.run(
            server: server,
            credentials: credentials,
            transport: transport,
            initialTerminalState: initialTerminalState,
            logger: logger,
            shouldContinueConnection: context.isCurrent,
            onAttempt: { attempt in
                context.updateConnectionState(
                    TerminalConnectionAttemptPolicy.state(
                        attempt: attempt,
                        hasEstablishedConnection: hasEstablishedConnection
                    )
                )
            },
            startupPlan: context.startupPlan,
            restoreMoshShell: context.restoreMoshShell,
            registerShell: { shell in
                guard await context.registerShell(shell) else { return false }
                context.updateConnectionState(.connected)
                if shell.origin == .fresh, let cwd = context.workingDirectory() {
                    await applyWorkingDirectory(
                        cwd,
                        shellId: shell.id,
                        sshClient: sshClient,
                        logger: logger
                    )
                }
                if shell.transport == .mosh {
                    await context.persistMoshCheckpoint(shell.id)
                }
                return true
            },
            onTitleChange: context.updateTitle,
            writeOutput: writeOutput,
            shouldResetClient: { sshError in
                switch sshError {
                case .notConnected, .connectionFailed, .socketError, .timeout:
                    return true
                case .channelOpenFailed, .shellRequestFailed:
                    let hasOtherRegistrations = await context.hasOtherRegistrations()
                    return !hasOtherRegistrations
                case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyApprovalRequired, .hostKeyVerificationFailed, .moshServerMissing, .moshServerRuntimeBroken, .moshBootstrapFailed, .moshSessionFailed, .moshInvalidEndpoint, .moshUDPTimeout, .moshClientSessionFailed, .outputLimitExceeded, .unknown:
                    return false
                }
            },
            onProcessExit: context.handleShellEnd,
            onFailure: { error in
                guard context.isCurrent() else { return }
                reportFailure(error)
                context.handleFailure(error)
            }
        )
    }

    private static func initialTerminalState(
        for terminal: GhosttyTerminalView
    ) -> SSHConnectionInitialTerminalState {
        let size = terminal.terminalSize()
        return SSHConnectionInitialTerminalState(
            columns: Int(size?.columns ?? 80),
            rows: Int(size?.rows ?? 24),
            pixelSize: terminal.currentTerminalPixelSize
        )
    }

    private static func applyWorkingDirectory(
        _ cwd: String,
        shellId: UUID,
        sshClient: SSHClient,
        logger: Logger
    ) async {
        let environment = await sshClient.remoteEnvironment()
        guard environment.shellProfile.family != .unknown else { return }
        let restorePlan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: cwd,
            environment: environment
        )
        guard case .command(let command) = restorePlan else {
            if case .keepDefault(let reason) = restorePlan {
                logger.warning(
                    "Keeping the default remote directory [reason: \(reason.rawValue, privacy: .public)]"
                )
            }
            return
        }
        guard let payload = command.data(using: .utf8) else { return }
        try? await sshClient.write(payload, to: shellId)
    }
}
