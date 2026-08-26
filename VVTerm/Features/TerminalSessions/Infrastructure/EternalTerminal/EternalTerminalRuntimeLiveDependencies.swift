import Foundation

@MainActor
extension EternalTerminalRuntimeDependencies {
    static func live(
        resumeStore: any EternalTerminalResumeStoring,
        analyticsTracker: AnalyticsTracker,
        remoteSessions: any TerminalRemoteSessionServicing,
        sshClientFactory: SSHClientFactory
    ) -> Self {
        Self(
            recordEvent: { event in
                switch event {
                case .connectionAttempted:
                    analyticsTracker.trackConnectionAttempted(
                        transport: ShellTransport.eternalTerminal.rawValue
                    )
                case .connectionReconnecting:
                    analyticsTracker.trackConnectionReconnecting(
                        transport: ShellTransport.eternalTerminal.rawValue
                    )
                case .connectionFailed(let reason):
                    analyticsTracker.trackConnectionFailed(
                        transport: ShellTransport.eternalTerminal.rawValue,
                        reason: reason
                    )
                }
            },
            remoteSessionKiller: LiveEternalTerminalRemoteSessionKiller(
                remoteSessions: remoteSessions
            ),
            sessionPreparer: LiveEternalTerminalSessionPreparer(
                resumeStore: resumeStore,
                sshClientFactory: sshClientFactory
            )
        )
    }
}

private nonisolated struct LiveEternalTerminalRemoteSessionKiller: EternalTerminalRemoteSessionKilling {
    let remoteSessions: any TerminalRemoteSessionServicing

    func killSession(_ identifier: RemoteSessionIdentifier, using client: SSHClient) async {
        await remoteSessions.killSession(identifier, using: client, runtime: nil)
    }
}
