import ETSession
import Foundation
import MoshBootstrap

extension KnownHostsManager: ServerHostKeyRepository {}

nonisolated enum ServerConnectionTestPlan: Equatable, Sendable {
    case sshOnly
    case mosh(portRange: ClosedRange<Int>)
    case eternalTerminal(port: UInt16)

    init(server: Server) {
        switch server.connectionMode {
        case .standard, .tailscale, .cloudflare:
            self = .sshOnly
        case .mosh:
            self = .mosh(portRange: 60_001...61_000)
        case .eternalTerminal:
            let port = server.eternalTerminalPort
            let resolvedPort: UInt16 = (1...Int(UInt16.max)).contains(port) ? UInt16(port) : 2_022
            self = .eternalTerminal(port: resolvedPort)
        }
    }
}

nonisolated enum ServerConnectionApprovalRequirement: Equatable, Sendable {
    case credentialEndpoint
    case hostKey(host: String, port: Int)
}

nonisolated enum ServerConnectionApprovalPolicy {
    static func requirement(
        for error: Error,
        server: Server
    ) -> ServerConnectionApprovalRequirement? {
        if let credentialError = error as? ServerCredentialAccessError,
           credentialError == .approvalRequired {
            return .credentialEndpoint
        }
        if let sshError = error as? SSHError,
           case .hostKeyApprovalRequired = sshError {
            return .hostKey(host: server.host, port: server.port)
        }
        return nil
    }
}

@MainActor
struct ServerFormDependencies {
    let credentials: any ServerCredentialRepository
    let connectionTester: any ServerConnectionTesting
    let hostKeys: any ServerHostKeyRepository

    static var live: Self {
        let hostKeys = KnownHostsManager.shared
        return Self(
            credentials: KeychainManager.shared,
            connectionTester: AppServerConnectionTester(
                hostKeys: hostKeys,
                now: Date.init
            ),
            hostKeys: hostKeys
        )
    }
}

nonisolated final class AppServerConnectionTester: ServerConnectionTesting, @unchecked Sendable {
    private let hostKeys: any ServerHostKeyRepository
    private let now: @Sendable () -> Date

    init(
        hostKeys: any ServerHostKeyRepository,
        now: @escaping @Sendable () -> Date
    ) {
        self.hostKeys = hostKeys
        self.now = now
    }

    func test(server: Server, credentials: ServerCredentials) async -> ServerConnectionTestResult {
        let plan = ServerConnectionTestPlan(server: server)
        do {
            try Task.checkCancellation()
            try await SSHConnectionOperationService.shared.withTemporaryConnection(
                server: server,
                credentials: credentials
            ) { client in
                try Task.checkCancellation()
                switch plan {
                case .sshOnly:
                    break
                case .mosh(let portRange):
                    let connectInfo = try await RemoteMoshManager.shared.bootstrapConnectInfo(
                        using: client,
                        startCommand: "exec true",
                        portRange: portRange
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
                case .eternalTerminal(let port):
                    let session = ETTerminalSession(
                        host: server.host,
                        port: port,
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
        if let approval = ServerConnectionApprovalPolicy.requirement(for: error, server: server),
           case .hostKey(let host, let port) = approval {
            hostKeyChallenge = hostKeys.pendingChallenge(
                for: host,
                port: port,
                now: now()
            )
        } else {
            hostKeyChallenge = nil
        }

        return ServerConnectionTestFailure(
            reason: .message(message),
            requiresCloudflareOverrides: requiresCloudflareOverrides,
            hostKeyChallenge: hostKeyChallenge
        )
    }
}
