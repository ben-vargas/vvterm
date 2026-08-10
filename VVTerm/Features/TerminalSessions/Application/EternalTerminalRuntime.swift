import Foundation
import os.log

nonisolated enum EternalTerminalStatePolicy {
    static func connectionState(
        for state: EternalTerminalSessionState,
        host: String,
        port: Int
    ) -> ConnectionState? {
        switch state {
        case .idle:
            return nil
        case .bootstrapping, .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnected, .reconnecting:
            // swift-et owns recovery. Publishing `.disconnected` here would make
            // VVTerm replace a session that is already reconnecting itself.
            return .reconnecting(attempt: 1)
        case .failed(let error):
            return .failed(.eternalTerminal(
                failure: error,
                host: host,
                port: port
            ))
        case .closed:
            return .disconnected
        }
    }
}

nonisolated enum EternalTerminalFailureAnalytics {
    static func analyticsCategory(for failure: EternalTerminalSessionFailure) -> String {
        switch failure {
        case .bootstrapSSH, .bootstrapResponse, .malformedBootstrapCredentials:
            return "bootstrap"
        case .transport: return "network"
        case .invalidKey: return "authentication"
        case .protocolMismatch: return "protocol"
        case .disconnectedBufferFull: return "buffer"
        case .connectionInProgress, .connectionClosed, .applicationSuspended: return "lifecycle"
        case .sessionUnrecoverable: return "recovery"
        case .client: return "client"
        case .resumeState, .unknown: return "unknown"
        }
    }
}

nonisolated enum EternalTerminalStartupCommand {
    static func remoteScriptPath(token: UUID) -> String {
        "/tmp/vvterm-et-start-\(token.uuidString.lowercased()).sh"
    }

    static func script(command: String, remotePath: String) -> String {
        """
        rm -f -- \(RemoteTerminalBootstrap.shellQuoted(remotePath))
        \(command)
        """
    }

    static func invocation(remotePath: String) -> String {
        "/bin/sh \(RemoteTerminalBootstrap.shellQuoted(remotePath))"
    }
}

nonisolated enum EternalTerminalResumePolicy {
    static func shouldDiscardCredentials(
        after failure: EternalTerminalSessionFailure
    ) -> Bool {
        return switch failure {
        case .invalidKey, .connectionClosed, .sessionUnrecoverable:
            true
        case .resumeState(_, let discardStoredState):
            discardStoredState
        case .bootstrapSSH, .bootstrapResponse, .malformedBootstrapCredentials,
             .transport, .protocolMismatch, .disconnectedBufferFull,
             .connectionInProgress, .applicationSuspended, .client, .unknown:
            false
        }
    }
}

nonisolated struct EternalTerminalRecoveryProbe {
    private enum State: Equatable, Sendable {
        case idle
        case pending(UUID)
        case completed(UUID)
    }

    private var state = State.idle

    mutating func begin() -> UUID {
        let id = UUID()
        state = .pending(id)
        return id
    }

    var pendingID: UUID? {
        guard case .pending(let id) = state else { return nil }
        return id
    }

    mutating func recordConnected(eventProbeID: UUID?) {
        guard case .pending(let pendingID) = state,
              eventProbeID == pendingID else { return }
        state = .completed(pendingID)
    }

    func didComplete(_ id: UUID) -> Bool {
        state == .completed(id)
    }

    mutating func reset() {
        state = .idle
    }
}

@MainActor
final class EternalTerminalRuntime {
    let paneId: UUID
    let identityToken = UUID()

    private let server: Server
    private let sessionRequest: EternalTerminalSessionRequest
    private let dependencies: EternalTerminalRuntimeDependencies
    private weak var tabManager: TerminalTabManager?
    private var session: (any EternalTerminalSession)?
    private weak var outputSink: (any TerminalOutputSink)?
    private var outputTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var reconnectEventActive = false
    private var failureReported = false
    private var networkRecoveryProbe = EternalTerminalRecoveryProbe()
    private var startupApplied = false
    private var tmuxLifecycle: EternalTerminalTmuxResumeContext?
    private var tmuxLifecycleParser: TmuxLifecycleStreamParser?
    private var lastTerminalSize: (cols: Int, rows: Int, pixels: TerminalPixelSize?) = (0, 0, nil)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "EternalTerminal"
    )

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        tabManager: TerminalTabManager,
        dependencies: EternalTerminalRuntimeDependencies
    ) {
        self.paneId = paneId
        self.server = server
        self.tabManager = tabManager
        self.dependencies = dependencies
        sessionRequest = EternalTerminalSessionRequest(
            paneId: paneId,
            server: server,
            credentials: credentials
        )
    }

    var isStartInFlight: Bool { connectTask != nil }

    private var isCurrentOwner: Bool {
        tabManager?.isCurrentEternalTerminalRuntime(self, for: paneId) == true
    }

    func abortConnection() {
        outputSink = nil
        networkRecoveryProbe.reset()
        if let session = detachActiveSession() {
            Task { await session.close() }
        }
    }

    func attach(to outputSink: any TerminalOutputSink) {
        self.outputSink = outputSink
    }

    func startIfNeeded() {
        guard connectTask == nil, stateTask == nil else { return }

        let paneId = paneId
        let host = server.host
        let port = server.eternalTerminalPort

        dependencies.record(.connectionAttempted)

        connectTask = Task { [weak self] in
            do {
                guard let self else { return }
                let prepared = try await self.prepareSession()
                guard !Task.isCancelled,
                      self.isCurrentOwner else {
                    await prepared.session.close()
                    return
                }
                self.session = prepared.session
                self.configureLifecycle(for: prepared.origin)
                self.observe(prepared.session, host: host, port: port)
                try await prepared.session.connect()
                guard self.isCurrentOwner else {
                    await prepared.session.close()
                    return
                }
                await self.persistCheckpoint()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.publishFailure(error, host: host, port: port)
            }
            self?.connectTask = nil
        }

        tabManager?.markEternalTerminalTransport(for: paneId)
    }

    func send(_ data: Data) {
        guard let session else { return }
        Task(priority: .userInitiated) { [logger] in
            do {
                try await session.send(data)
            } catch {
                logger.warning("Failed to send ET input: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func sendInteractiveScript(_ script: String) async throws {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        guard let session else { throw EternalTerminalSessionFailure.connectionClosed }
        try await session.send(data)
    }

    func withBootstrapSSHClient<Result: Sendable>(
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        guard let session else { throw EternalTerminalSessionFailure.connectionClosed }
        return try await session.withBootstrapSSHClient(operation)
    }

    func killManagedTmuxSession(named sessionName: String) async {
        do {
            try await withBootstrapSSHClient { [dependencies] client in
                await dependencies.killTmuxSession(
                    named: sessionName,
                    using: client
                )
            }
        } catch {
            logger.warning("Failed to clean up ET tmux session: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resize(cols: Int, rows: Int, pixelSize: TerminalPixelSize?) {
        guard cols > 0, rows > 0 else { return }
        guard cols != lastTerminalSize.cols
                || rows != lastTerminalSize.rows
                || pixelSize != lastTerminalSize.pixels else { return }
        lastTerminalSize = (cols, rows, pixelSize)
        guard let session else { return }
        Task(priority: .userInitiated) { [logger] in
            do {
                try await session.resize(
                    rows: rows,
                    cols: cols,
                    pixelWidth: pixelSize?.width,
                    pixelHeight: pixelSize?.height
                )
            } catch {
                logger.debug("Failed to send ET terminal size: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func beginNetworkRecoveryProbe() async -> UUID? {
        guard let session,
              isCurrentOwner else {
            return nil
        }
        let probeID = networkRecoveryProbe.begin()
        await session.notifyNetworkPathChanged()
        guard isCurrentOwner else {
            return nil
        }
        return probeID
    }

    func notifyNetworkPathChanged() async {
        await session?.notifyNetworkPathChanged()
    }

    func completedNetworkRecoveryProbe(_ probeID: UUID) -> Bool {
        isCurrentOwner && networkRecoveryProbe.didComplete(probeID)
    }

    func persistCheckpoint() async {
        guard let session else { return }
        do {
            try await session.persistCheckpoint { [weak self] in
                self?.isCurrentOwner == true
            }
        } catch EternalTerminalSessionFailure.connectionClosed {
            return
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Failed to save ET recovery checkpoint: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prepareForApplicationBackground() async {
        guard let session else { return }
        do {
            try await session.prepareForApplicationBackground { [weak self] in
                self?.isCurrentOwner == true
            }
        } catch EternalTerminalSessionFailure.connectionClosed {
            return
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Failed to save ET background checkpoint: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resumeFromApplicationBackground() async {
        await session?.resumeFromApplicationBackground()
    }

    func close() async {
        let session = detachActiveSession()
        outputSink = nil
        await session?.close()
    }

    private func detachActiveSession() -> (any EternalTerminalSession)? {
        connectTask?.cancel()
        outputTask?.cancel()
        stateTask?.cancel()
        connectTask = nil
        outputTask = nil
        stateTask = nil
        networkRecoveryProbe.reset()
        let activeSession = session
        session = nil
        return activeSession
    }

    private func prepareSession() async throws -> PreparedEternalTerminalSession {
        let paneId = paneId
        let server = server
        let runtimeToken = identityToken
        return try await dependencies.sessionPreparer.prepareSession(
            request: sessionRequest,
            startupPlanProvider: { [weak tabManager] client in
                guard let tabManager else { throw CancellationError() }
                return try await tabManager.tmuxCoordinator.eternalTerminalStartupPlan(
                    for: paneId,
                    serverId: server.id,
                    client: client,
                    runtimeToken: runtimeToken
                )
            },
            isCurrentOwner: { [weak self] in
                self?.isCurrentOwner == true
            }
        )
    }

    private func observe(
        _ session: any EternalTerminalSession,
        host: String,
        port: Int
    ) {
        outputTask = Task { [weak self] in
            for await data in session.output {
                guard !Task.isCancelled else { return }
                self?.consumeOutput(data)
            }
        }

        stateTask = Task { [weak self] in
            for await state in session.stateChanges {
                guard !Task.isCancelled, let self else { return }
                await self.handle(state, session: session, host: host, port: port)
            }
        }
    }

    private func configureLifecycle(for origin: EternalTerminalSessionOrigin) {
        guard origin == .resumed else { return }
        startupApplied = true
        let context = tabManager?.eternalTerminalTmuxResumeContext(for: paneId)
        tmuxLifecycle = context
        tmuxLifecycleParser = context.map {
            TmuxLifecycleStreamParser(markerToken: $0.markerToken)
        }
    }

    private func handle(
        _ state: EternalTerminalSessionState,
        session: any EternalTerminalSession,
        host: String,
        port: Int
    ) async {
        guard isCurrentOwner else {
            return
        }
        let recoveryProbeIDAtEvent = networkRecoveryProbe.pendingID
        if state == .reconnecting || state == .disconnected {
            if !reconnectEventActive {
                reconnectEventActive = true
                dependencies.record(.connectionReconnecting)
            }
        } else if state == .connected {
            reconnectEventActive = false
            do {
                if lastTerminalSize.cols > 0, lastTerminalSize.rows > 0 {
                    try await session.resize(
                        rows: lastTerminalSize.rows,
                        cols: lastTerminalSize.cols,
                        pixelWidth: lastTerminalSize.pixels?.width,
                        pixelHeight: lastTerminalSize.pixels?.height
                    )
                    guard isCurrentOwner else { return }
                    applyStartupPlanIfNeeded()
                } else {
                    logger.error("ET connected without a valid terminal grid")
                    return
                }
            } catch {
                publishFailure(error, host: host, port: port)
                return
            }
        }

        if case .failed(let error) = state {
            publishFailure(error, host: host, port: port)
            return
        }

        guard let connectionState = EternalTerminalStatePolicy.connectionState(
            for: state,
            host: host,
            port: port
        ) else { return }
        guard isCurrentOwner else {
            return
        }
        if state == .connected {
            networkRecoveryProbe.recordConnected(eventProbeID: recoveryProbeIDAtEvent)
        }
        tabManager?.updatePaneState(paneId, connectionState: connectionState)
        tabManager?.markEternalTerminalTransport(for: paneId)
    }

    private func applyStartupPlanIfNeeded() {
        guard !startupApplied else { return }
        startupApplied = true
        guard let session else { return }
        Task { [weak self] in
            let plan = await session.preparedStartupPlan()
            guard let self,
                  self.isCurrentOwner else { return }
            let resumeContext = plan.tmuxLifecycle.map {
                EternalTerminalTmuxResumeContext(
                    ownership: $0.ownership,
                    markerToken: $0.markerToken
                )
            }
            tmuxLifecycle = resumeContext
            tmuxLifecycleParser = resumeContext.map {
                TmuxLifecycleStreamParser(markerToken: $0.markerToken)
            }
            tabManager?.setEternalTerminalTmuxResumeContext(
                resumeContext,
                for: paneId
            )
            guard let command = plan.command,
                  let data = "\(command)\r".data(using: .utf8) else { return }
            do {
                try await session.send(data)
            } catch {
                publishFailure(error, host: server.host, port: server.eternalTerminalPort)
            }
        }
    }

    private func consumeOutput(_ data: Data) {
        guard isCurrentOwner else {
            return
        }
        guard var parser = tmuxLifecycleParser else {
            outputSink?.receiveTerminalOutput(data)
            return
        }
        let result = parser.consume(data)
        tmuxLifecycleParser = parser
        if !result.output.isEmpty {
            outputSink?.receiveTerminalOutput(result.output)
        }
        guard let event = result.events.last, let tmuxLifecycle else { return }
        let reason: TerminalShellEndReason
        switch event {
        case .detached:
            reason = .tmuxDetached(tmuxLifecycle.ownership)
        case .ended:
            reason = .tmuxEnded(tmuxLifecycle.ownership)
        case .creationFailed:
            reason = .tmuxCreationFailed
        }
        tabManager?.handleShellEnd(for: paneId, reason: reason)
        Task { [weak tabManager] in
            await tabManager?.unregisterEternalTerminalRuntime(
                for: paneId,
                ifOwnedBy: self
            )
        }
    }

    private func publishFailure(_ error: Error, host: String, port: Int) {
        guard isCurrentOwner else {
            logger.info(
                "Ignoring failure from stale ET runtime for pane \(self.paneId.uuidString, privacy: .public)"
            )
            return
        }
        let failure = error as? EternalTerminalSessionFailure ?? .unknown
        if EternalTerminalResumePolicy.shouldDiscardCredentials(after: failure) {
            do {
                try dependencies.sessionPreparer.discardResumeState(for: paneId)
            } catch {
                logger.error("Failed to invalidate ET resume credentials: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !failureReported {
            failureReported = true
            dependencies.record(
                .connectionFailed(
                    reason: EternalTerminalFailureAnalytics.analyticsCategory(
                        for: failure
                    )
                )
            )
        }
        tabManager?.updatePaneState(
            paneId,
            connectionState: .failed(.eternalTerminal(
                failure: failure,
                host: host,
                port: port
            ))
        )
        tabManager?.markEternalTerminalTransport(for: paneId)
    }
}
