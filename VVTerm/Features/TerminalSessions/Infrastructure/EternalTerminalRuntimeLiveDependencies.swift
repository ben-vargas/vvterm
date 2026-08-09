import Foundation

@MainActor
extension EternalTerminalRuntimeDependencies {
    static var live: Self {
        Self(
            recordEvent: { event in
                switch event {
                case .connectionAttempted:
                    AnalyticsTracker.shared.trackConnectionAttempted(
                        transport: ShellTransport.eternalTerminal.rawValue
                    )
                case .connectionReconnecting:
                    AnalyticsTracker.shared.trackConnectionReconnecting(
                        transport: ShellTransport.eternalTerminal.rawValue
                    )
                case .connectionFailed(let reason):
                    AnalyticsTracker.shared.trackConnectionFailed(
                        transport: ShellTransport.eternalTerminal.rawValue,
                        reason: reason
                    )
                }
            },
            tmuxSessionKiller: LiveEternalTerminalTmuxSessionKiller(
                remoteTmux: RemoteTmuxManager.shared
            )
        )
    }
}

private nonisolated struct LiveEternalTerminalTmuxSessionKiller: EternalTerminalTmuxSessionKilling {
    let remoteTmux: RemoteTmuxManager

    func killSession(named sessionName: String, using client: SSHClient) async {
        await remoteTmux.killSession(named: sessionName, using: client)
    }
}
