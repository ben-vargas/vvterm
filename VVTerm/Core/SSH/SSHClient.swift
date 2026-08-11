import Foundation
import Darwin
import os.log
import MoshCore
import MoshBootstrap

// MARK: - SSH Client using libssh2

actor SSHClient {
    private struct ConnectingState {
        let id: UUID
        let key: String
        let task: Task<SSHSession, Error>
        var pendingSession: SSHSession?
        let startupTrace: SSHStartupTrace
    }

    private struct ConnectedState {
        let id: UUID
        let key: String
        var server: Server
        let session: SSHSession
        var remoteEnvironment: RemoteEnvironment?
        var remoteTerminalType: RemoteTerminalType?
        let startupTrace: SSHStartupTrace
    }

    private struct AbortedState {
        let operationID: UUID?
        let session: SSHSession?
        let connectTask: Task<SSHSession, Error>?
    }

    private struct DisconnectOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum Lifecycle {
        case disconnected
        case connecting(ConnectingState)
        case connected(ConnectedState)
        case disconnecting(DisconnectOperation)
        case failed
        case aborted(AbortedState)
    }

    private struct MoshShellRuntime {
        let session: MoshClientSession
        let output: TerminalOutputChannel
        let streamTask: Task<Void, Never>
    }

    private struct PreparedMoshShell: Sendable {
        let session: MoshClientSession
        let pendingOps: [MoshHostOp]
    }

    private struct PreparedMoshBootstrap: Sendable {
        let shell: PreparedMoshShell
        let leaseID: UUID
        let lease: RemoteMoshServerLease
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSH")
    private var keepAliveTask: Task<Void, Never>?
    private var lifecycle: Lifecycle = .disconnected
    private var moshRuntimeGeneration = UUID()
    private var moshShells: [UUID: MoshShellRuntime] = [:]
    private var pendingMoshServerLeases: [UUID: RemoteMoshServerLease] = [:]
    private let cloudflareTransportManager = CloudflareTransportManager()
    private let moshStartupTimeout: Duration = .seconds(8)
    private let connectTimeout: Duration
    private let disconnectTimeout: Duration = .seconds(4)
    private let execTimeout: Duration = .seconds(20)
    private let uploadTimeout: Duration = .seconds(60)
    private let runtimeSettings: SSHRuntimeSettings
    private let hostKeyVerifier: any SSHHostKeyVerifying
    private let moshBootstrap: any SSHMoshBootstrapping

    init(
        connectTimeout: Duration = .seconds(30),
        runtimeSettings: SSHRuntimeSettings,
        hostKeyVerifier: any SSHHostKeyVerifying,
        moshBootstrap: any SSHMoshBootstrapping
    ) {
        self.connectTimeout = connectTimeout
        self.runtimeSettings = runtimeSettings
        self.hostKeyVerifier = hostKeyVerifier
        self.moshBootstrap = moshBootstrap
    }

    #if DEBUG
    func runtimeSettingsForTesting() -> SSHRuntimeSettings {
        runtimeSettings
    }

    func hostKeyDecisionForTesting(
        _ candidate: SSHHostKeyCandidate
    ) -> SSHHostKeyVerificationDecision {
        hostKeyVerifier.verify(candidate)
    }

    func bootstrapMoshForTesting(
        execute: @escaping SSHMoshCommandExecutor
    ) async throws -> MoshServerConnectInfo {
        try await moshBootstrap.bootstrapConnectInfo(
            terminalType: .xterm256Color,
            startCommand: nil,
            portRange: 60_001...61_000,
            execute: execute
        )
    }

    func terminateMoshForTesting(
        pid: Int32,
        execute: @escaping SSHMoshCommandExecutor
    ) async {
        await moshBootstrap.terminateMoshServer(pid: pid, execute: execute)
    }
    #endif

    /// Check if the client has been aborted
    var isAborted: Bool {
        switch lifecycle {
        case .aborted, .disconnecting:
            return true
        case .disconnected, .connecting, .connected, .failed:
            return false
        }
    }

    var lifecyclePhase: LifecyclePhase {
        switch lifecycle {
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnecting:
            return .disconnecting
        case .failed:
            return .failed
        case .aborted:
            return .aborted
        }
    }

    private var session: SSHSession? {
        guard case .connected(let state) = lifecycle else { return nil }
        return state.session
    }

    private var connectedServer: Server? {
        guard case .connected(let state) = lifecycle else { return nil }
        return state.server
    }

    private var startupTrace: SSHStartupTrace? {
        switch lifecycle {
        case .connecting(let state):
            return state.startupTrace
        case .connected(let state):
            return state.startupTrace
        case .disconnected, .disconnecting, .failed, .aborted:
            return nil
        }
    }

    func probeLiveTransport(
        shellId: UUID,
        transport: ShellTransport
    ) async -> Bool {
        if transport == .mosh {
            guard let runtime = moshShells[shellId] else { return false }
            if case .running = await runtime.session.state {
                return true
            }
            return false
        }

        guard let session else { return false }
        let marker = "__VVTERM_WAKE_PROBE_\(UUID().uuidString)__"
        do {
            let output = try await HardOperationDeadline.run(
                timeout: .seconds(3),
                onTimeout: { session.abort() },
                operation: { try await session.execute("echo \(marker)") }
            )
            return output.contains(marker)
        } catch {
            return false
        }
    }

    /// Interrupts an active or pending transport before bounded cleanup starts.
    func abortConnection() {
        moshRuntimeGeneration = UUID()
        switch lifecycle {
        case .connecting(let state):
            state.task.cancel()
            state.pendingSession?.abort()
            lifecycle = .aborted(
                AbortedState(
                    operationID: state.id,
                    session: state.pendingSession,
                    connectTask: state.task
                )
            )
        case .connected(let state):
            state.session.abort()
            lifecycle = .aborted(
                AbortedState(operationID: state.id, session: state.session, connectTask: nil)
            )
        case .disconnecting:
            break
        case .disconnected, .failed, .aborted:
            lifecycle = .aborted(
                AbortedState(operationID: nil, session: nil, connectTask: nil)
            )
        }
    }

    // MARK: - Connection

    func connect(to server: Server, credentials: ServerCredentials) async throws -> SSHSession {
        let key = connectionKey(for: server)

        connectionPreparation: while true {
            try Task.checkCancellation()

            switch lifecycle {
            case .disconnecting(let operation):
                await operation.task.value

            case .aborted(let state) where state.session != nil || state.connectTask != nil:
                await disconnect()

            case .connected(let state):
                let transportIsConnected = await state.session.isConnected
                guard case .connected(let currentState) = lifecycle,
                      currentState.id == state.id,
                      currentState.session === state.session else {
                    continue
                }

                switch SSHConnectedSessionPolicy.action(
                    existingConnectionKey: state.key,
                    requestedConnectionKey: key,
                    transportIsConnected: transportIsConnected
                ) {
                case .reuse:
                    var updatedState = currentState
                    updatedState.server = server
                    lifecycle = .connected(updatedState)
                    return updatedState.session

                case .recover:
                    state.session.abort()
                    lifecycle = .aborted(
                        AbortedState(operationID: state.id, session: state.session, connectTask: nil)
                    )
                    await disconnect()

                case .reject:
                    throw SSHError.connectionFailed("SSH client already connected")
                }

            case .connecting(let state) where state.key == key:
                return try await resolveConnection(
                    operationID: state.id,
                    key: key,
                    server: server,
                    task: state.task
                )

            case .connecting:
                throw SSHError.connectionFailed("SSH client already connected")

            case .disconnected, .failed, .aborted:
                break connectionPreparation
            }
        }

        let startupTrace = SSHStartupTrace(logger: logger)
        let operationID = UUID()
        let task = Task {
            try await performConnectionAttempt(
                operationID: operationID,
                server: server,
                credentials: credentials,
                startupTrace: startupTrace
            )
        }
        lifecycle = .connecting(
            ConnectingState(
                id: operationID,
                key: key,
                task: task,
                pendingSession: nil,
                startupTrace: startupTrace
            )
        )
        return try await resolveConnection(
            operationID: operationID,
            key: key,
            server: server,
            task: task
        )
    }

    private func connectionKey(for server: Server) -> String {
        "\(server.host):\(server.port):\(server.username):\(server.connectionMode):\(server.authMethod):\(server.cloudflareAccessMode?.rawValue ?? "none"):\(server.cloudflareTeamDomainOverride ?? "")"
    }

    private func performConnectionAttempt(
        operationID: UUID,
        server: Server,
        credentials: ServerCredentials,
        startupTrace: SSHStartupTrace
    ) async throws -> SSHSession {
        logger.info(
            "Connecting to \(server.host, privacy: .private(mask: .hash)):\(server.port, privacy: .private(mask: .hash)) [mode: \(server.connectionMode.rawValue, privacy: .public)]"
        )
        logger.info("Auth method: \(String(describing: server.authMethod)), password present: \(credentials.password != nil)")
        let transportToken = startupTrace.begin(.transportPreparation)

        var dialHost = server.host
        var dialPort = server.port

        if server.connectionMode == .cloudflare {
            let localPort = try await cloudflareTransportManager.connect(
                server: server,
                credentials: credentials
            )
            dialHost = "127.0.0.1"
            dialPort = Int(localPort)
            logger.info("Using Cloudflare local tunnel endpoint \(dialHost):\(dialPort)")
        } else {
            await disconnectCloudflareTransport(reason: "pre-connect cleanup")
        }

        guard case .connecting(let currentState) = lifecycle,
              currentState.id == operationID,
              !Task.isCancelled else {
            if shouldCleanupConnectionTransport(for: operationID) {
                await disconnectCloudflareTransport(reason: "cancelled transport preparation")
            }
            throw CancellationError()
        }
        startupTrace.end(transportToken, detail: server.connectionMode.rawValue)

        let config = SSHSessionConfig(
            host: server.host,
            port: server.port,
            dialHost: dialHost,
            dialPort: dialPort,
            hostKeyHost: server.host,
            hostKeyPort: server.port,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            credentials: credentials,
            keepAlive: runtimeSettings.keepAlive
        )
        let pendingSession = SSHSession(
            config: config,
            hostKeyVerifier: hostKeyVerifier,
            startupTrace: startupTrace
        )

        guard case .connecting(var connectingState) = lifecycle,
              connectingState.id == operationID else {
            pendingSession.abort()
            throw CancellationError()
        }
        connectingState.pendingSession = pendingSession
        lifecycle = .connecting(connectingState)

        do {
            try await HardOperationDeadline.run(
                timeout: connectTimeout,
                onTimeout: {
                    startupTrace.recordOnce(
                        .connectionDeadline,
                        outcome: "timeout"
                    )
                    pendingSession.abort()
                }
            ) {
                try await pendingSession.connect()
            }
            try Task.checkCancellation()
            return pendingSession
        } catch {
            pendingSession.abort()
            Task.detached(priority: .utility) {
                await pendingSession.disconnect()
            }
            if error is HardOperationDeadlineError {
                throw SSHError.timeout
            }
            throw error
        }
    }

    private func resolveConnection(
        operationID: UUID,
        key: String,
        server: Server,
        task: Task<SSHSession, Error>
    ) async throws -> SSHSession {
        do {
            let connectedSession = try await task.value
            guard !Task.isCancelled, !task.isCancelled else {
                connectedSession.abort()
                await connectedSession.disconnect()
                if case .connecting(let state) = lifecycle, state.id == operationID {
                    lifecycle = .aborted(AbortedState(
                        operationID: operationID,
                        session: connectedSession,
                        connectTask: nil
                    ))
                }
                if shouldCleanupConnectionTransport(for: operationID) {
                    await disconnectCloudflareTransport(reason: "connect cancellation")
                }
                throw CancellationError()
            }

            switch lifecycle {
            case .connecting(let state) where state.id == operationID:
                lifecycle = .connected(
                    ConnectedState(
                        id: operationID,
                        key: key,
                        server: server,
                        session: connectedSession,
                        remoteEnvironment: nil,
                        remoteTerminalType: nil,
                        startupTrace: state.startupTrace
                    )
                )
                startKeepAlive(policy: connectedSession.config.keepAlive)
                logger.info("Connected to \(server.host, privacy: .private(mask: .hash))")
                return connectedSession
            case .connected(var state)
                where state.id == operationID && state.session === connectedSession:
                state.server = server
                lifecycle = .connected(state)
                return connectedSession
            default:
                connectedSession.abort()
                await connectedSession.disconnect()
                if shouldCleanupConnectionTransport(for: operationID) {
                    await disconnectCloudflareTransport(reason: "stale connect completion")
                }
                throw CancellationError()
            }
        } catch {
            let ownsFailure: Bool
            if case .connecting(let state) = lifecycle, state.id == operationID {
                ownsFailure = true
            } else {
                ownsFailure = false
            }
            if shouldCleanupConnectionTransport(for: operationID) {
                await disconnectCloudflareTransport(reason: "connect failure")
            }
            if ownsFailure,
               case .connecting(let state) = lifecycle,
               state.id == operationID {
                lifecycle = .failed
            }
            if server.connectionMode == .cloudflare,
               case SSHError.connectionFailed(let message) = error,
               message.contains("SSH handshake failed: -13") {
                throw SSHError.cloudflareTunnelFailed(
                    String(
                        localized: "Cloudflare tunnel connected, but SSH handshake was closed by the upstream target. Verify Access policy and service token scope."
                    )
                )
            }
            throw error
        }
    }

    private func shouldCleanupConnectionTransport(for operationID: UUID) -> Bool {
        switch lifecycle {
        case .connecting(let state):
            return state.id == operationID
        case .connected(let state):
            return state.id == operationID
        case .aborted(let state):
            return state.operationID == operationID
        case .disconnected, .disconnecting, .failed:
            return true
        }
    }

    func disconnect() async {
        if case .disconnecting(let operation) = lifecycle {
            await operation.task.value
            return
        }

        moshRuntimeGeneration = UUID()

        let activeSession: SSHSession?
        switch lifecycle {
        case .connecting(let state):
            state.task.cancel()
            state.pendingSession?.abort()
            activeSession = state.pendingSession
        case .connected(let state):
            activeSession = state.session
        case .aborted(let state):
            state.connectTask?.cancel()
            state.session?.abort()
            activeSession = state.session
        case .disconnected, .disconnecting, .failed:
            activeSession = nil
        }

        let pendingMoshServerLeases = Array(self.pendingMoshServerLeases.values)
        self.pendingMoshServerLeases.removeAll()
        let activeMoshShells = Array(moshShells.values)
        moshShells.removeAll()

        keepAliveTask?.cancel()
        keepAliveTask = nil

        let operationID = UUID()
        let disconnectTimeout = self.disconnectTimeout
        let cloudflareTransportManager = self.cloudflareTransportManager
        let logger = self.logger
        let task = Task {
            let cleanupFinished = await SSHClient.cleanupPendingMoshServerLeases(
                pendingMoshServerLeases
            )
            if !cleanupFinished {
                logger.warning(
                    "Pending remote mosh-server cleanup exceeded the disconnect coordination window"
                )
            }

            for runtime in activeMoshShells {
                runtime.streamTask.cancel()
                await runtime.output.cancel()
                await runtime.session.stop()
            }

            await SSHClient.disconnectSSHSession(
                activeSession,
                timeout: disconnectTimeout,
                logger: logger
            )
            await SSHClient.disconnectCloudflareTransport(
                cloudflareTransportManager,
                reason: "client disconnect",
                logger: logger
            )
            self.finishDisconnect(operationID: operationID)
            logger.info("Disconnected")
        }
        lifecycle = .disconnecting(DisconnectOperation(id: operationID, task: task))
        await task.value
    }

    // MARK: - Command Execution

    func execute(
        _ command: String,
        timeout: Duration? = nil,
        maxOutputBytes: Int = SSHExecOutputBudget.defaultMaximumBytes
    ) async throws -> String {
        guard !isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }
        let effectiveTimeout = timeout ?? execTimeout
        return try await SSHClient.runWithDeadline(
            effectiveTimeout,
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            return try await session.execute(command, maxOutputBytes: maxOutputBytes)
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        guard !isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }

        logger.info(
            "Starting SSH upload [path: \(remotePath, privacy: .private(mask: .hash))] [bytes: \(data.count)] [strategy: \(String(describing: strategy), privacy: .public)]"
        )
        try await SSHClient.runWithDeadline(
            uploadTimeout,
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            try await session.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func remoteEnvironment(forceRefresh: Bool = false) async -> RemoteEnvironment {
        if !forceRefresh,
           case .connected(let state) = lifecycle,
           let remoteEnvironment = state.remoteEnvironment {
            return remoteEnvironment
        }

        let connectionID: UUID?
        if case .connected(let state) = lifecycle {
            connectionID = state.id
        } else {
            connectionID = nil
        }
        let token = startupTrace?.begin(.remoteEnvironment)
        let environment = await RemoteEnvironmentResolver.resolve(using: self)
        if let token {
            startupTrace?.end(token, detail: environment.platform.rawValue)
        }
        if case .connected(var state) = lifecycle, state.id == connectionID {
            state.remoteEnvironment = environment
            lifecycle = .connected(state)
        }
        logger.info(
            "Resolved remote environment [platform: \(environment.platform.rawValue, privacy: .public), shell: \(environment.shellProfile.family.rawValue, privacy: .public), active: \(environment.activeShellName ?? "unknown", privacy: .private(mask: .hash))]"
        )
        return environment
    }

    func remoteTerminalType(forceRefresh: Bool = false) async -> RemoteTerminalType {
        if !forceRefresh,
           case .connected(let state) = lifecycle,
           let remoteTerminalType = state.remoteTerminalType {
            return remoteTerminalType
        }

        let environment = await remoteEnvironment(forceRefresh: forceRefresh)
        let connectionID: UUID?
        if case .connected(let state) = lifecycle {
            connectionID = state.id
        } else {
            connectionID = nil
        }
        let token = startupTrace?.begin(.terminalType)
        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: environment,
            execute: { [weak self] command, timeout in
                guard let self else { throw SSHError.notConnected }
                return try await self.execute(command, timeout: timeout)
            }
        )
        if let token {
            startupTrace?.end(token, detail: terminalType.rawValue)
        }
        if case .connected(var state) = lifecycle, state.id == connectionID {
            state.remoteTerminalType = terminalType
            lifecycle = .connected(state)
        }
        logger.info("Resolved remote terminal type: \(terminalType.rawValue, privacy: .public)")
        return terminalType
    }

    func remotePlatform(forceRefresh: Bool = false) async -> RemotePlatform {
        await remoteEnvironment(forceRefresh: forceRefresh).platform
    }

    func supportsTmuxRuntime() async -> Bool {
        let environment = await remoteEnvironment()
        return environment.supportsTmuxRuntime
    }

    func supportsMoshRuntime() async -> Bool {
        let environment = await remoteEnvironment()
        return environment.supportsMoshRuntime
    }

    // MARK: - Remote Files

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry] {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.listDirectory(at: path, maxEntries: maxEntries)
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.stat(at: path)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.lstat(at: path)
    }

    func readlink(at path: String) async throws -> String {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.readlink(at: path)
    }

    func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.readFile(at: path, maxBytes: maxBytes, offset: offset)
    }

    func fileSystemCapacity(at path: String) async throws -> RemoteFileFilesystemCapacity {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.fileSystemCapacity(at: path)
    }

    func downloadFile(at path: String, to localURL: URL, maxBytes: UInt64) async throws {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }

        logger.info(
            "Starting SSH download [remote: \(path, privacy: .private(mask: .hash))] [local: \(localURL.path, privacy: .private(mask: .hash))]"
        )
        try await SSHClient.runWithDeadline(
            Self.streamTransferTimeout(for: maxBytes),
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            try await session.downloadFile(at: path, to: localURL, maxBytes: maxBytes)
        }
    }

    func writeFile(_ data: Data, to path: String, permissions: Int32 = 0o644) async throws {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await SSHClient.runWithDeadline(
            uploadTimeout,
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            try await session.writeFile(data, to: path, permissions: permissions)
        }
    }

    func upload(
        fileAt localURL: URL,
        to remotePath: String,
        expectedBytes: UInt64,
        permissions: Int32 = 0o644
    ) async throws {
        guard !isAborted, let session else {
            throw SSHError.notConnected
        }
        logger.info(
            "Starting streamed SSH upload [path: \(remotePath, privacy: .private(mask: .hash))] [bytes: \(expectedBytes)]"
        )
        try await SSHClient.runWithDeadline(
            Self.streamTransferTimeout(for: expectedBytes),
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            try await session.writeFile(
                from: localURL,
                to: remotePath,
                expectedBytes: expectedBytes,
                permissions: permissions
            )
        }
    }

    func resolveHomeDirectory() async throws -> String {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.resolveHomeDirectory()
    }

    func createDirectory(at path: String, permissions: Int32 = 0o755) async throws {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.createDirectory(at: path, permissions: permissions)
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.setPermissions(at: path, permissions: permissions)
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.renameItem(at: sourcePath, to: destinationPath)
    }

    func deleteFile(at path: String) async throws {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.deleteFile(at: path)
    }

    func deleteDirectory(at path: String) async throws {
        guard !isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.deleteDirectory(at: path)
    }

    // MARK: - Shell

    func startShell(
        cols: Int = 80,
        rows: Int = 24,
        pixelSize: TerminalPixelSize? = nil,
        startupCommand: String? = nil
    ) async throws -> ShellHandle {
        try Task.checkCancellation()
        guard !isAborted, let sshSession = session else {
            throw SSHError.notConnected
        }

        let connectionMode = connectedServer?.connectionMode ?? .standard
        let environment = await remoteEnvironment()
        try validateShellStartupSession(sshSession)
        let terminalType = await remoteTerminalType()
        try validateShellStartupSession(sshSession)
        if connectionMode != .mosh {
            let sshShell = try await startValidatedSSHShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                pixelSize: pixelSize,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
            return ShellHandle(
                id: sshShell.id,
                stream: sshShell.stream,
                transportState: .ssh
            )
        }

        guard environment.platform != .windows && environment.shellProfile.family == .posix else {
            logger.warning("Mosh requested, but remote environment does not support Mosh runtime. Falling back to SSH.")
            let fallbackToken = startupTrace?.begin(.sshFallback)
            let fallbackShell = try await startValidatedSSHShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                pixelSize: pixelSize,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
            if let fallbackToken { startupTrace?.end(fallbackToken, detail: "unsupported_remote") }
            return ShellHandle(
                id: fallbackShell.id,
                stream: fallbackShell.stream,
                transportState: .sshFallback(
                    reason: .unsupportedRemoteCapabilities,
                    diagnostics: MoshFallbackDiagnostics.make(
                        reason: .unsupportedRemoteCapabilities,
                        events: startupTrace?.snapshot() ?? []
                    )
                )
            )
        }

        do {
            let preparedMosh = try await prepareMoshShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                startupCommand: startupCommand,
                terminalType: terminalType
            )
            do {
                try validateShellStartupSession(sshSession)
            } catch {
                await discardPreparedMoshShell(preparedMosh)
                throw error
            }
            pendingMoshServerLeases.removeValue(forKey: preparedMosh.leaseID)
            return registerMoshShell(preparedMosh.shell)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if let sshError = error as? SSHError, case .notConnected = sshError {
                throw sshError
            }
            let moshError = error
            let fallbackReason = fallbackReason(for: moshError)
            logger.warning("Mosh startup failed, using SSH fallback: \(moshError.localizedDescription)")

            do {
                let fallbackToken = startupTrace?.begin(.sshFallback)
                let fallbackShell = try await startValidatedSSHShell(
                    using: sshSession,
                    cols: cols,
                    rows: rows,
                    pixelSize: pixelSize,
                    startupCommand: startupCommand,
                    environment: environment,
                    terminalType: terminalType
                )
                if let fallbackToken {
                    startupTrace?.end(fallbackToken, detail: fallbackReason.rawValue)
                }
                return ShellHandle(
                    id: fallbackShell.id,
                    stream: fallbackShell.stream,
                    transportState: .sshFallback(
                        reason: fallbackReason,
                        diagnostics: MoshFallbackDiagnostics.make(
                            reason: fallbackReason,
                            events: startupTrace?.snapshot() ?? []
                        )
                    )
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if let sshError = error as? SSHError, case .notConnected = sshError {
                    throw sshError
                }
                throw SSHError.moshSessionFailed(
                    "Mosh startup failed (\(moshError.localizedDescription)); SSH fallback failed (\(error.localizedDescription))"
                )
            }
        }
    }

    private func startValidatedSSHShell(
        using expectedSession: SSHSession,
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize?,
        startupCommand: String?,
        environment: RemoteEnvironment,
        terminalType: RemoteTerminalType
    ) async throws -> ShellHandle {
        try validateShellStartupSession(expectedSession)
        let shell = try await expectedSession.startShell(
            cols: cols,
            rows: rows,
            pixelSize: pixelSize,
            startupCommand: startupCommand,
            environment: environment,
            terminalType: terminalType
        )
        do {
            try validateShellStartupSession(expectedSession)
            return shell
        } catch {
            await expectedSession.closeShell(shell.id)
            throw error
        }
    }

    private func validateShellStartupSession(_ expectedSession: SSHSession) throws {
        try Task.checkCancellation()
        guard !isAborted,
              let currentSession = session,
              currentSession === expectedSession else {
            throw SSHError.notConnected
        }
    }

    func write(_ data: Data, to shellId: UUID) async throws {
        guard !isAborted else {
            throw SSHError.notConnected
        }

        if let runtime = moshShells[shellId] {
            do {
                try await runtime.session.enqueue(.keystrokes(data))
                return
            } catch {
                throw SSHError.moshSessionFailed(error.localizedDescription)
            }
        }

        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.write(data, to: shellId)
    }

    func resize(
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize? = nil,
        for shellId: UUID
    ) async throws {
        if let runtime = moshShells[shellId] {
            guard let wireSize = TerminalGeometryConversion.gridSize(cols: cols, rows: rows) else {
                throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
            }
            do {
                try await runtime.session.enqueue(.resize(cols: wireSize.cols, rows: wireSize.rows))
                return
            } catch {
                throw SSHError.moshSessionFailed(error.localizedDescription)
            }
        }

        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.resize(
            cols: cols,
            rows: rows,
            pixelSize: pixelSize,
            for: shellId
        )
    }

    func closeShell(_ shellId: UUID) async {
        if let runtime = moshShells.removeValue(forKey: shellId) {
            runtime.streamTask.cancel()
            await runtime.output.cancel()
            await runtime.session.stop()
            return
        }

        guard let session = session else { return }
        await session.closeShell(shellId)
    }

    func prepareMoshShellForApplicationBackground(
        _ shellId: UUID
    ) async throws -> MoshSnapshot? {
        guard let runtime = moshShells[shellId] else { return nil }
        return try await runtime.session.prepareForApplicationBackground()
    }

    func resumeMoshShellFromApplicationBackground(_ shellId: UUID) async throws {
        guard let runtime = moshShells[shellId] else { return }
        try await runtime.session.resumeFromApplicationBackground()
    }

    func moshSnapshot(for shellId: UUID) async throws -> MoshSnapshot? {
        guard let runtime = moshShells[shellId] else { return nil }
        return try await runtime.session.makeSnapshot()
    }

    // MARK: - Keep Alive

    private func startKeepAlive(policy: SSHKeepAlivePolicy) {
        keepAliveTask?.cancel()
        keepAliveTask = nil

        guard case .enabled(let intervalSeconds) = policy else { return }

        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                await session?.sendKeepAlive()
            }
        }
    }

    private func finishDisconnect(operationID: UUID) {
        guard case .disconnecting(let operation) = lifecycle,
              operation.id == operationID else {
            return
        }
        lifecycle = .aborted(
            AbortedState(operationID: nil, session: nil, connectTask: nil)
        )
    }

    nonisolated static func cleanupPendingMoshServerLeases(
        _ leases: [RemoteMoshServerLease]
    ) async -> Bool {
        guard !leases.isEmpty else { return true }

        // This task is deliberately unstructured so cancellation of the caller
        // cannot shorten the cleanup window before the remote PID is known.
        return await Task {
            do {
                try await runWithDeadline(RemoteMoshManager.disconnectCleanupTimeout) {
                    await withTaskGroup(of: Void.self) { group in
                        for lease in leases {
                            group.addTask {
                                await lease.cleanup()
                            }
                        }
                    }
                }
                return true
            } catch {
                // Cleanup continues in its unstructured operation task, but the
                // disconnect path does not wait beyond this coordination bound.
                return false
            }
        }.value
    }

    private nonisolated static func disconnectSSHSession(
        _ activeSession: SSHSession?,
        timeout: Duration,
        logger: Logger
    ) async {
        guard let activeSession else { return }

        do {
            try await runWithDeadline(
                timeout,
                onTimeout: {
                    logger.warning("Timed out while disconnecting SSH session; aborting socket")
                    activeSession.abort()
                }
            ) {
                await activeSession.disconnect()
            }
        } catch SSHError.timeout {
            // The deadline callback already aborted the socket.
        } catch {
            activeSession.abort()
        }
    }

    private func disconnectCloudflareTransport(reason: String) async {
        await SSHClient.disconnectCloudflareTransport(
            cloudflareTransportManager,
            reason: reason,
            logger: logger
        )
    }

    private nonisolated static func disconnectCloudflareTransport(
        _ manager: CloudflareTransportManager,
        reason: String,
        logger: Logger
    ) async {
        await manager.disconnect()
        logger.debug("Cloudflare disconnect coordination completed (\(reason, privacy: .public))")
    }

    // MARK: - State

    var isConnected: Bool {
        get async {
            await session?.isConnected ?? false
        }
    }

    // MARK: - Mosh

    func restoreMoshShell(
        from snapshot: MoshSnapshot,
        cols: Int,
        rows: Int
    ) async throws -> ShellHandle {
        guard !isAborted else { throw SSHError.notConnected }
        guard let wireSize = TerminalGeometryConversion.gridSize(cols: cols, rows: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        let generation = moshRuntimeGeneration
        let restoredSession = try await MoshRestoreStartup.run(
            restore: {
                try await MoshClientSession.restore(from: snapshot)
            },
            start: { session in
                try await session.start()
            },
            resize: { session in
                try await session.enqueue(
                    .resize(cols: wireSize.cols, rows: wireSize.rows)
                )
            },
            isCurrent: {
                await self.acceptsMoshRestore(generation)
            },
            stop: { session in
                await session.stop()
            }
        )
        guard acceptsMoshRestore(generation) else {
            await restoredSession.stop()
            throw CancellationError()
        }
        return registerMoshShell(
            PreparedMoshShell(
                session: restoredSession,
                pendingOps: []
            ),
            origin: .restored
        )
    }

    private func acceptsMoshRestore(_ generation: UUID) -> Bool {
        moshRuntimeGeneration == generation && !isAborted
    }

    private func prepareMoshShell(
        using expectedSession: SSHSession,
        cols: Int,
        rows: Int,
        startupCommand: String?,
        terminalType: RemoteTerminalType
    ) async throws -> PreparedMoshBootstrap {
        let configuredHost = connectedServer?.host ?? ""
        let peerHost = await expectedSession.remoteEndpointHost()
        try validateShellStartupSession(expectedSession)
        let candidateHosts = MoshEndpointCandidatePolicy.hosts(
            configuredHost: configuredHost,
            sshPeerHost: peerHost
        )
        guard !candidateHosts.isEmpty else { throw SSHError.moshInvalidEndpoint }

        let terminateServer: @Sendable (Int32) async -> Void = { pid in
            await self.moshBootstrap.terminateMoshServer(
                pid: pid,
                execute: { command, timeout in
                    try await SSHClient.runWithDeadline(
                        timeout,
                        onTimeout: { expectedSession.abort() }
                    ) {
                        try await expectedSession.execute(command)
                    }
                }
            )
        }
        let leaseID = UUID()
        let lease = RemoteMoshServerLease(terminate: terminateServer)
        pendingMoshServerLeases[leaseID] = lease

        let bootstrapToken = startupTrace?.begin(.moshBootstrap)
        let connectInfo: MoshServerConnectInfo
        do {
            connectInfo = try await moshBootstrap.bootstrapConnectInfo(
                terminalType: terminalType,
                startCommand: startupCommand,
                portRange: 60001...61000,
                execute: { command, timeout in
                    try await SSHClient.runWithDeadline(
                        timeout,
                        onTimeout: { expectedSession.abort() }
                    ) {
                        try await expectedSession.execute(command)
                    }
                }
            )
            await lease.activate(serverPID: connectInfo.serverPID)
            if let bootstrapToken {
                startupTrace?.end(
                    bootstrapToken,
                    detail: RemoteMoshManager.portClass(Int(connectInfo.port)).rawValue
                )
            }
        } catch {
            if let bootstrapToken {
                startupTrace?.end(
                    bootstrapToken,
                    outcome: "failed",
                    detail: fallbackReason(for: error).rawValue
                )
            }
            await lease.bootstrapFailed()
            pendingMoshServerLeases.removeValue(forKey: leaseID)
            throw error
        }

        do {
            let preparedShell = try await prepareMoshShellStartup(
                using: expectedSession,
                configuredHost: configuredHost,
                candidateHosts: candidateHosts,
                connectInfo: connectInfo,
                cols: cols,
                rows: rows
            )
            return PreparedMoshBootstrap(
                shell: preparedShell,
                leaseID: leaseID,
                lease: lease
            )
        } catch {
            await lease.cleanup()
            pendingMoshServerLeases.removeValue(forKey: leaseID)
            throw error
        }
    }

    private func discardPreparedMoshShell(_ prepared: PreparedMoshBootstrap) async {
        await prepared.lease.cleanup()
        await prepared.shell.session.stop()
        pendingMoshServerLeases.removeValue(forKey: prepared.leaseID)
    }

    private func prepareMoshShellStartup(
        using expectedSession: SSHSession,
        configuredHost: String,
        candidateHosts: [String],
        connectInfo: MoshServerConnectInfo,
        cols: Int,
        rows: Int
    ) async throws -> PreparedMoshShell {
        try validateShellStartupSession(expectedSession)
        guard let wireSize = TerminalGeometryConversion.gridSize(cols: cols, rows: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        let startupTimeout = candidateHosts.count > 1 ? Duration.seconds(4) : moshStartupTimeout
        var lastStartupError: Error?
        var moshSession: MoshClientSession?
        var pendingOps: [MoshHostOp] = []

        for host in candidateHosts {
            try validateShellStartupSession(expectedSession)
            let endpointClass = host == configuredHost ? "configured" : "ssh_peer"
            startupTrace?.record(
                .moshEndpoint,
                stageMilliseconds: 0,
                outcome: "selected",
                detail: endpointClass
            )
            let udpToken = startupTrace?.begin(.moshUDPSession)
            let endpoint = MoshEndpoint(
                host: host,
                port: connectInfo.port,
                keyBase64_22: connectInfo.key
            )
            let candidateSession = MoshClientSession(endpoint: endpoint)

            do {
                pendingOps = try await SSHClient.runWithDeadline(
                    startupTimeout,
                    onTimeout: {
                        Task { await candidateSession.stop() }
                    }
                ) {
                    try await candidateSession.start()
                    try await candidateSession.enqueue(
                        .resize(cols: wireSize.cols, rows: wireSize.rows)
                    )
                    return try await SSHClient.waitForMoshTransportReadiness {
                        await candidateSession.drainHostOps()
                    }
                }
                moshSession = candidateSession
                if let udpToken { startupTrace?.end(udpToken, detail: endpointClass) }
                if host != configuredHost {
                    logger.info("Using SSH peer endpoint for Mosh: \(host, privacy: .private(mask: .hash))")
                }
                break
            } catch {
                await candidateSession.stop()
                if let udpToken {
                    startupTrace?.end(udpToken, outcome: "failed", detail: endpointClass)
                }
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastStartupError = error
                if host != candidateHosts.last {
                    logger.warning("Mosh startup failed for endpoint \(host, privacy: .private(mask: .hash)), trying next candidate")
                }
            }
        }

        guard let moshSession else {
            if let sshError = lastStartupError as? SSHError,
               case .timeout = sshError {
                throw SSHError.moshUDPTimeout
            }
            if let lastStartupError {
                throw SSHError.moshClientSessionFailed(lastStartupError.localizedDescription)
            }
            throw SSHError.moshClientSessionFailed("Failed to start Mosh session")
        }

        do {
            try validateShellStartupSession(expectedSession)
            return PreparedMoshShell(
                session: moshSession,
                pendingOps: pendingOps
            )
        } catch {
            await moshSession.stop()
            throw error
        }
    }

    private func registerMoshShell(
        _ prepared: PreparedMoshShell,
        origin: ShellStartOrigin = .fresh
    ) -> ShellHandle {
        let shellId = UUID()
        if !prepared.pendingOps.isEmpty {
            logger.info("Mosh: \(prepared.pendingOps.count) pending host ops before stream creation")
        }

        let output = TerminalOutputChannel(overflowPolicy: .rejectNewData)
        let moshLogger = logger
        let trace = startupTrace
        let streamTask = Task { [weak self] in
            var totalBytes = 0
            var shouldContinue = true

            for op in prepared.pendingOps {
                guard !Task.isCancelled,
                      let bytes = MoshStartupReadiness.visibleTerminalBytes(from: op) else {
                    continue
                }
                trace?.recordOnce(.firstTerminalByte, detail: "mosh")
                guard await output.send(bytes) else {
                    shouldContinue = false
                    break
                }
                let (newTotal, overflow) = totalBytes.addingReportingOverflow(bytes.count)
                totalBytes = overflow ? Int.max : newTotal
            }

            while shouldContinue, !Task.isCancelled {
                let hostOps = await prepared.session.drainHostOps()
                for hostOp in hostOps {
                    guard !Task.isCancelled else {
                        shouldContinue = false
                        break
                    }
                    if let bytes = MoshStartupReadiness.visibleTerminalBytes(from: hostOp) {
                        trace?.recordOnce(.firstTerminalByte, detail: "mosh")
                        guard await output.send(bytes) else {
                            shouldContinue = false
                            break
                        }
                        let (newTotal, overflow) = totalBytes.addingReportingOverflow(bytes.count)
                        totalBytes = overflow ? Int.max : newTotal
                        moshLogger.debug("Mosh host bytes: \(bytes.count)B (total: \(totalBytes))")
                    }
                }

                guard shouldContinue, !Task.isCancelled else { break }
                if hostOps.isEmpty {
                    switch await prepared.session.state {
                    case .idle, .stopped, .failed:
                        shouldContinue = false
                    case .starting, .running, .suspending, .suspended, .stopping:
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            if !Task.isCancelled {
                await output.finish()
                moshLogger.info("Mosh stream ended, total bytes delivered: \(totalBytes)")
                await self?.moshOutputDidFinish(shellId)
            } else {
                await output.cancel()
            }
        }

        moshShells[shellId] = MoshShellRuntime(
            session: prepared.session,
            output: output,
            streamTask: streamTask
        )

        return ShellHandle(
            id: shellId,
            stream: TerminalOutputStream(channel: output),
            transportState: .mosh,
            origin: origin
        )
    }

    private func moshOutputDidFinish(_ shellId: UUID) async {
        guard let runtime = moshShells.removeValue(forKey: shellId) else { return }
        await runtime.session.stop()
    }

    nonisolated static func waitForMoshTransportReadiness(
        pollInterval: Duration = .milliseconds(20),
        draining drainHostOps: @escaping @Sendable () async -> [MoshHostOp]
    ) async throws -> [MoshHostOp] {
        while true {
            try Task.checkCancellation()
            let drained = await drainHostOps()
            if MoshStartupReadiness.isTransportEstablished(by: drained) {
                return drained
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    nonisolated static func runWithDeadline<T: Sendable>(
        _ timeout: Duration,
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await HardOperationDeadline.run(
                timeout: timeout,
                onTimeout: onTimeout,
                operation: operation
            )
        } catch is HardOperationDeadlineError {
            throw SSHError.timeout
        }
    }

    /// Allows slow large transfers while keeping one operation bounded.
    /// The timeout assumes at least 64 KiB/s and is capped at 24 hours.
    private nonisolated static func streamTransferTimeout(for byteCount: UInt64) -> Duration {
        let secondsForBytes = byteCount / UInt64(64 * 1_024)
        let secondsWithSetup = secondsForBytes.addingReportingOverflow(120)
        let requestedSeconds = secondsWithSetup.overflow ? UInt64.max : secondsWithSetup.partialValue
        return .seconds(Int64(min(requestedSeconds, 86_400)))
    }

    private func fallbackReason(for error: Error) -> MoshFallbackReason {
        guard let sshError = error as? SSHError else {
            return .sessionFailed
        }

        switch sshError {
        case .moshServerMissing:
            return .serverMissing
        case .moshServerRuntimeBroken:
            return .serverRuntimeBroken
        case .moshBootstrapFailed:
            return .bootstrapFailed
        case .moshInvalidEndpoint:
            return .invalidEndpoint
        case .moshUDPTimeout:
            return .udpTimeout
        case .moshClientSessionFailed:
            return .clientSessionFailed
        case .moshSessionFailed:
            return .sessionFailed
        default:
            return .sessionFailed
        }
    }
}
