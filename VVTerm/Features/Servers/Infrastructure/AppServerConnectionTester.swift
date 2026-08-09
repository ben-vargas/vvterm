import ETSession
import Foundation
import MoshBootstrap

extension KnownHostsManager: ServerHostKeyRepository {}

@MainActor
struct ServerFormDependencies {
    let credentials: any ServerCredentialRepository
    let connectionTester: any ServerConnectionTesting
    let hostKeys: any ServerHostKeyRepository

    static var live: Self {
        let hostKeys = KnownHostsManager.shared
        return Self(
            credentials: KeychainManager.shared,
            connectionTester: AppServerConnectionTester(hostKeys: hostKeys),
            hostKeys: hostKeys
        )
    }
}

nonisolated final class AppServerConnectionTester: ServerConnectionTesting, @unchecked Sendable {
    private let hostKeys: any ServerHostKeyRepository

    init(hostKeys: any ServerHostKeyRepository) {
        self.hostKeys = hostKeys
    }

    func test(server: Server, credentials: ServerCredentials) async -> ServerConnectionTestResult {
        do {
            try Task.checkCancellation()
            try await SSHConnectionOperationService.shared.withTemporaryConnection(
                server: server,
                credentials: credentials
            ) { client in
                try Task.checkCancellation()
                if server.connectionMode == .mosh {
                    let connectInfo = try await RemoteMoshManager.shared.bootstrapConnectInfo(
                        using: client,
                        startCommand: "exec true",
                        portRange: 60_001...61_000
                    )
                    await RemoteMoshManager.terminateBootstrappedServer(
                        pid: connectInfo.serverPID,
                        terminate: { pid in
                            await RemoteMoshManager.shared.terminateMoshServer(
                                pid: pid,
                                execute: { command, timeout in
                                    try await client.execute(command, timeout: timeout)
                                }
                            )
                        }
                    )
                } else if server.connectionMode == .eternalTerminal {
                    let session = ETTerminalSession(
                        host: server.host,
                        port: UInt16(exactly: server.eternalTerminalPort) ?? 2_022,
                        bootstrapExecutor: SSHETBootstrapExecutor(connectedClient: client),
                        bootstrapOptions: SSHETBootstrapExecutor.bootstrapOptions
                    )
                    do {
                        try await session.connect()
                        await session.close()
                    } catch {
                        await session.close()
                        throw error
                    }
                }
            }
            try Task.checkCancellation()
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(failure(for: error, server: server))
        }
    }

    private func failure(for error: Error, server: Server) -> ServerConnectionTestFailure {
        let baseMessage = server.connectionMode == .eternalTerminal
            ? EternalTerminalErrorPresentation.message(
                for: error,
                host: server.host,
                port: server.eternalTerminalPort
            )
            : error.localizedDescription
        let message: String
        if server.connectionMode == .tailscale {
            let reminder = String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback).")
            message = baseMessage.contains(reminder) ? baseMessage : "\(baseMessage)\n\(reminder)"
        } else {
            message = baseMessage
        }

        let requiresCloudflareOverrides: Bool
        let hostKeyChallenge: KnownHostsManager.Challenge?
        if let sshError = error as? SSHError,
           case .cloudflareConfigurationRequired = sshError {
            requiresCloudflareOverrides = true
        } else {
            requiresCloudflareOverrides = false
        }
        if let sshError = error as? SSHError,
           case .hostKeyApprovalRequired = sshError {
            hostKeyChallenge = hostKeys.pendingChallenge(
                for: server.host,
                port: server.port,
                now: Date()
            )
        } else {
            hostKeyChallenge = nil
        }

        return ServerConnectionTestFailure(
            message: message,
            requiresCloudflareOverrides: requiresCloudflareOverrides,
            hostKeyChallenge: hostKeyChallenge
        )
    }
}
