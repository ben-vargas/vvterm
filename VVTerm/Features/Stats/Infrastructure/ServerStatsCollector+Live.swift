import Foundation

extension ServerStatsCollectorDependencies {
    static var live: Self {
        let connectionOperations = SSHConnectionOperationService.shared
        return ServerStatsCollectorDependencies(
            makeClient: { SSHClient() },
            loadCredentials: { server in
                try KeychainManager.shared.getCredentials(for: server)
            },
            runWithConnection: { client, server, credentials, disconnectWhenDone, operation in
                try await connectionOperations.runWithConnection(
                    using: client,
                    server: server,
                    credentials: credentials,
                    disconnectWhenDone: disconnectWhenDone,
                    operation: operation
                )
            },
            makeAttemptID: UUID.init,
            now: Date.init
        )
    }
}

extension ServerStatsCollector {
    convenience init() {
        self.init(dependencies: .live)
    }
}
