import Foundation

nonisolated protocol RemoteSessionBackend: Sendable {
    var metadata: RemoteSessionBackendMetadata { get }

    func managedIdentifier(
        deviceID: String,
        entityID: UUID,
        serverName: String
    ) throws -> RemoteSessionIdentifier
    func availability(using client: SSHClient) async -> RemoteSessionAvailability
    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor]
    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionBackendLaunchPlan
    func installScript(
        attachment: RemoteSessionAttachment,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        using client: SSHClient,
        attachAfterInstall: Bool
    ) async -> String?
    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws
    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async -> String?
}

extension RemoteSessionBackend {
    nonisolated func managedIdentifier(
        deviceID: String,
        entityID: UUID,
        serverName: String
    ) throws -> RemoteSessionIdentifier {
        try RemoteSessionManagedIdentifierPolicy.identifier(
            backendIdentifier: metadata.identifier,
            serverName: serverName,
            deviceID: deviceID,
            entityID: entityID
        )
    }
}
