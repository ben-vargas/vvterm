import Combine
import Foundation

nonisolated enum TerminalNetworkReadiness: String, Hashable, Sendable {
    case unknown
    case ready
    case unavailable
}

nonisolated protocol TerminalRemoteTmuxServicing: Sendable {
    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability
    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend?
    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async throws -> [RemoteTmuxSession]
    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend?
    ) async
    func sendScript(
        _ script: String,
        using client: SSHClient,
        shellId: UUID
    ) async throws
    func killSession(
        named sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async
    func cleanupLegacySessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async
    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async
    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async -> String?
}

nonisolated protocol TerminalRemoteMoshServicing: Sendable {
    func installMoshServer(using client: SSHClient) async throws
}

@MainActor
struct TerminalNetworkReadinessSource {
    let initial: TerminalNetworkReadiness
    let updates: AnyPublisher<TerminalNetworkReadiness, Never>
}

@MainActor
struct TerminalSessionApplicationEffects {
    let authorizeServer: (Server) async -> Bool
    let refreshLiveActivity: ([ConnectionState]) -> Void
    let recordSuccessfulConnection: (UUID, String) -> Void
    let noteTerminalSessionEnded: (Bool) -> Void
    let recordSplitPaneCreated: () -> Void
}

@MainActor
struct TerminalTmuxConfiguration {
    struct ServerSettings {
        let name: String
        let enabledOverride: Bool?
        let startupBehaviorOverride: TmuxStartupBehavior?
    }

    let deviceID: String
    let enabledByDefault: () -> Bool
    let startupBehaviorByDefault: () -> TmuxStartupBehavior
    let serverSettings: (UUID) -> ServerSettings?
    let themeStyle: () -> RemoteTmuxThemeStyle
}

@MainActor
struct TerminalTabManagerDependencies {
    let networkReadiness: TerminalNetworkReadinessSource
    let applicationIsActive: () -> Bool
    let effects: TerminalSessionApplicationEffects
    let tmuxConfiguration: TerminalTmuxConfiguration
    let remoteTmux: any TerminalRemoteTmuxServicing
    let remoteMosh: any TerminalRemoteMoshServicing
    let eternalTerminalRuntime: EternalTerminalRuntimeDependencies
}

#if DEBUG
extension TerminalTabManagerDependencies {
    static func testing(
        networkReadinessPublisher: AnyPublisher<TerminalNetworkReadiness, Never>?,
        liveActivityRefresh: @escaping ([ConnectionState]) -> Void
    ) -> Self {
        let updates = networkReadinessPublisher
            ?? Empty<TerminalNetworkReadiness, Never>().eraseToAnyPublisher()
        return Self(
            networkReadiness: TerminalNetworkReadinessSource(
                initial: .ready,
                updates: updates
            ),
            applicationIsActive: { true },
            effects: TerminalSessionApplicationEffects(
                authorizeServer: { _ in true },
                refreshLiveActivity: liveActivityRefresh,
                recordSuccessfulConnection: { _, _ in },
                noteTerminalSessionEnded: { _ in },
                recordSplitPaneCreated: {}
            ),
            tmuxConfiguration: TerminalTmuxConfiguration(
                deviceID: "test-device",
                enabledByDefault: { true },
                startupBehaviorByDefault: { .askEveryTime },
                serverSettings: { _ in nil },
                themeStyle: {
                    TerminalTabManager.remoteTmuxThemeStyle(for: nil)
                }
            ),
            remoteTmux: UnavailableTerminalRemoteTmuxService(),
            remoteMosh: UnavailableTerminalRemoteMoshService(),
            eternalTerminalRuntime: .testing
        )
    }
}

private actor UnavailableTerminalRemoteTmuxService: TerminalRemoteTmuxServicing {
    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability {
        .unsupported
    }

    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        nil
    }

    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async throws -> [RemoteTmuxSession] {
        throw SSHError.notConnected
    }

    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend?
    ) async {}

    func sendScript(
        _ script: String,
        using client: SSHClient,
        shellId: UUID
    ) async throws {
        throw SSHError.notConnected
    }

    func killSession(
        named sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {}

    func cleanupLegacySessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {}

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {}

    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async -> String? {
        nil
    }
}

private actor UnavailableTerminalRemoteMoshService: TerminalRemoteMoshServicing {
    func installMoshServer(using client: SSHClient) async throws {
        throw SSHError.notConnected
    }
}
#endif
