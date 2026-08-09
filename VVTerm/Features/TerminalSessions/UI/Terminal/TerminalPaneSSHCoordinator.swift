import Foundation
import CoreGraphics
import os.log

final class TerminalPaneSSHCoordinator {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    weak var terminal: GhosttyTerminalView?
    let sshClient: SSHClient
    let tabManager: TerminalTabManager
    var isTerminalReady = false
    var preservePane = false
    var lastReportedSize: CGSize = .zero

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
        guard let client = tabManager.getSSHClient(for: paneId),
              let shellId = tabManager.shellId(for: paneId) else {
            return nil
        }

        return (client: client, shellId: shellId)
    }

    func startSSHConnection(terminal: GhosttyTerminalView) {
        let paneId = self.paneId
        if tabManager.shellId(for: paneId) != nil {
            tabManager.updatePaneState(paneId, connectionState: .connected)
            logger.debug("Reusing existing shell for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        let sshClient = self.sshClient
        let server = self.server
        let credentials = self.credentials
        let logger = self.logger
        let hasEstablishedConnection = tabManager.paneStates[paneId]?.hasEstablishedConnection == true
        guard tabManager.startSSHConnectionTask(
            for: paneId,
            server: server,
            client: sshClient,
            operation: { [weak terminal] context in
                guard let terminal else { return }
                await Self.runConnection(
                    server: server,
                    credentials: credentials,
                    sshClient: sshClient,
                    terminal: terminal,
                    context: context,
                    hasEstablishedConnection: hasEstablishedConnection,
                    logger: logger
                )
            }
        ) else {
            if tabManager.shellId(for: paneId) != nil {
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
        terminal: GhosttyTerminalView,
        context: TerminalSSHConnectionContext,
        hasEstablishedConnection: Bool,
        logger: Logger
    ) async {
        await SSHConnectionRunner.run(
            server: server,
            credentials: credentials,
            sshClient: sshClient,
            terminal: terminal,
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
                        await context.persistMoshSnapshot(shell.id)
                    }
                    return true
                },
                onBeforeShellStart: { _, _ in },
                onTitleChange: context.updateTitle,
                shouldContinueStreaming: { data, terminal in
                    guard context.isCurrent() else { return false }
                    terminal.feedData(data)
                    return true
                },
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
                onFailure: { error, terminal in
                    guard context.isCurrent() else { return }
                    let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                    if let data = errorMsg.data(using: .utf8) {
                        terminal.feedData(data)
                    }
                    context.handleFailure(error)
                }
        )
    }

    func cancelShell() {
        terminal = nil
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
