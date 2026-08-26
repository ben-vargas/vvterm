import Combine
import Foundation

nonisolated enum TerminalNetworkReadiness: String, Hashable, Sendable {
    case unknown
    case ready
    case unavailable
}

nonisolated enum TerminalRemoteSessionDefaults {
    static let enabledKey = "terminalRemoteSessionEnabledDefault"
    static let backendIdentifierKey = "terminalRemoteSessionBackendIdentifierDefault"
    static let startupBehaviorKey = "terminalRemoteSessionStartupBehaviorDefault"
    static let legacyEnabledKey = "terminalTmuxEnabledDefault"
    static let legacyStartupBehaviorKey = "terminalTmuxStartupBehaviorDefault"
}

nonisolated protocol TerminalRemoteSessionServicing: Sendable {
    var backendMetadata: [RemoteSessionBackendMetadata] { get }
    func managedIdentifier(
        deviceID: String,
        entityID: UUID,
        serverName: String,
        backendIdentifier: RemoteSessionBackendIdentifier
    ) throws -> RemoteSessionIdentifier
    func availability(
        for backendIdentifier: RemoteSessionBackendIdentifier,
        using client: SSHClient
    ) async -> RemoteSessionAvailability
    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor]
    func prepareManagedSession(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        runtime: RemoteSessionRuntime
    ) async
    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) async throws -> RemoteSessionBackendLaunchPlan
    func installScript(
        attachment: RemoteSessionAttachment,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        using client: SSHClient,
        attachAfterInstall: Bool
    ) async -> String?
    func sendScript(
        _ script: String,
        using client: SSHClient,
        shellId: UUID
    ) async throws
    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async
    func cleanupSessions(
        keeping identifiers: Set<RemoteSessionIdentifier>,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async
    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async -> String?
}

extension TerminalRemoteSessionServicing {
    nonisolated func managedIdentifier(
        deviceID: String,
        entityID: UUID,
        serverName: String,
        backendIdentifier: RemoteSessionBackendIdentifier
    ) throws -> RemoteSessionIdentifier {
        try RemoteSessionManagedIdentifierPolicy.identifier(
            backendIdentifier: backendIdentifier,
            serverName: serverName,
            deviceID: deviceID,
            entityID: entityID
        )
    }

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
struct TerminalAppLockSource {
    let initialIsLocked: Bool
    let updates: AnyPublisher<Bool, Never>
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
struct TerminalRemoteSessionConfiguration {
    struct ServerSettings {
        let name: String
        let enabledOverride: Bool?
        let backendIdentifier: RemoteSessionBackendIdentifier
        let startupBehaviorOverride: RemoteSessionStartupBehavior?
    }

    let deviceID: String
    let enabledByDefault: () -> Bool
    let backendIdentifierByDefault: () -> RemoteSessionBackendIdentifier
    let startupBehaviorByDefault: () -> RemoteSessionStartupBehavior
    let serverSettings: (UUID) -> ServerSettings?
    let themeStyle: @MainActor () -> RemoteSessionThemeStyle
}

@MainActor
struct TerminalTabManagerDependencies {
    let sshClientFactory: SSHClientFactory
    let networkReadiness: TerminalNetworkReadinessSource
    let applicationIsActive: @MainActor @Sendable () -> Bool
    let appLock: TerminalAppLockSource
    let effects: TerminalSessionApplicationEffects
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
            sshClientFactory: .testing(),
            networkReadiness: TerminalNetworkReadinessSource(
                initial: .ready,
                updates: updates
            ),
            applicationIsActive: { true },
            appLock: TerminalAppLockSource(
                initialIsLocked: false,
                updates: Empty<Bool, Never>().eraseToAnyPublisher()
            ),
            effects: TerminalSessionApplicationEffects(
                authorizeServer: { _ in true },
                refreshLiveActivity: liveActivityRefresh,
                recordSuccessfulConnection: { _, _ in },
                noteTerminalSessionEnded: { _ in },
                recordSplitPaneCreated: {}
            ),
            remoteMosh: UnavailableTerminalRemoteMoshService(),
            eternalTerminalRuntime: .testing
        )
    }
}

private actor UnavailableTerminalRemoteMoshService: TerminalRemoteMoshServicing {
    func installMoshServer(using client: SSHClient) async throws {
        throw SSHError.notConnected
    }
}
#endif
