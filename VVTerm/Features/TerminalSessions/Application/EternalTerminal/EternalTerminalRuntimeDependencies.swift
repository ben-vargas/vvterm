import Foundation

nonisolated enum EternalTerminalRuntimeEvent: Equatable, Sendable {
    case connectionAttempted
    case connectionReconnecting
    case connectionFailed(reason: String)
}

nonisolated protocol EternalTerminalRemoteSessionKilling: Sendable {
    func killSession(_ identifier: RemoteSessionIdentifier, using client: SSHClient) async
}

nonisolated struct EternalTerminalRuntimeDependencies: Sendable {
    private let recordEvent: @MainActor @Sendable (EternalTerminalRuntimeEvent) -> Void
    private let remoteSessionKiller: any EternalTerminalRemoteSessionKilling
    let sessionPreparer: any EternalTerminalSessionPreparing

    init(
        recordEvent: @MainActor @Sendable @escaping (EternalTerminalRuntimeEvent) -> Void,
        remoteSessionKiller: any EternalTerminalRemoteSessionKilling,
        sessionPreparer: any EternalTerminalSessionPreparing
    ) {
        self.recordEvent = recordEvent
        self.remoteSessionKiller = remoteSessionKiller
        self.sessionPreparer = sessionPreparer
    }

    @MainActor
    func record(_ event: EternalTerminalRuntimeEvent) {
        recordEvent(event)
    }

    func killRemoteSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient
    ) async {
        await remoteSessionKiller.killSession(identifier, using: client)
    }
}

#if DEBUG
extension EternalTerminalRuntimeDependencies {
    static var testing: Self {
        Self(
            recordEvent: { _ in },
            remoteSessionKiller: NoOpEternalTerminalRemoteSessionKiller(),
            sessionPreparer: UnavailableEternalTerminalSessionPreparer()
        )
    }
}

private actor NoOpEternalTerminalRemoteSessionKiller: EternalTerminalRemoteSessionKilling {
    func killSession(_ identifier: RemoteSessionIdentifier, using client: SSHClient) async {}
}

@MainActor
private struct UnavailableEternalTerminalSessionPreparer: EternalTerminalSessionPreparing {
    func prepareSession(
        request: EternalTerminalSessionRequest,
        startupPlanProvider: @Sendable @escaping (SSHClient) async throws -> TerminalShellStartupPlan,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws -> PreparedEternalTerminalSession {
        throw CancellationError()
    }

    func discardResumeState(for paneId: UUID) throws {}
}
#endif
