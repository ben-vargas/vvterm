import Foundation

nonisolated enum EternalTerminalRuntimeEvent: Equatable, Sendable {
    case connectionAttempted
    case connectionReconnecting
    case connectionFailed(reason: String)
}

nonisolated protocol EternalTerminalTmuxSessionKilling: Sendable {
    func killSession(named sessionName: String, using client: SSHClient) async
}

nonisolated struct EternalTerminalRuntimeDependencies: Sendable {
    private let recordEvent: @MainActor @Sendable (EternalTerminalRuntimeEvent) -> Void
    private let tmuxSessionKiller: any EternalTerminalTmuxSessionKilling

    init(
        recordEvent: @MainActor @Sendable @escaping (EternalTerminalRuntimeEvent) -> Void,
        tmuxSessionKiller: any EternalTerminalTmuxSessionKilling
    ) {
        self.recordEvent = recordEvent
        self.tmuxSessionKiller = tmuxSessionKiller
    }

    @MainActor
    func record(_ event: EternalTerminalRuntimeEvent) {
        recordEvent(event)
    }

    func killTmuxSession(named sessionName: String, using client: SSHClient) async {
        await tmuxSessionKiller.killSession(named: sessionName, using: client)
    }
}

#if DEBUG
extension EternalTerminalRuntimeDependencies {
    static var testing: Self {
        Self(
            recordEvent: { _ in },
            tmuxSessionKiller: NoOpEternalTerminalTmuxSessionKiller()
        )
    }
}

private actor NoOpEternalTerminalTmuxSessionKiller: EternalTerminalTmuxSessionKilling {
    func killSession(named sessionName: String, using client: SSHClient) async {}
}
#endif
