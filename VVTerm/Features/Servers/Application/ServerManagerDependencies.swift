import Foundation

@MainActor
protocol ServerRemoteRepository: AnyObject {
    var isAvailable: Bool { get }
    func fetchServerChanges(forceFullFetch: Bool) async throws -> ServerRemoteChanges
    func saveServer(_ server: Server) async throws
    func saveWorkspace(_ workspace: Workspace) async throws
}

@MainActor
protocol ServerRemoteMutationClient: AnyObject {
    func saveServer(_ server: Server) async throws
    func deleteServer(_ server: Server) async throws
    func saveWorkspace(_ workspace: Workspace) async throws
    func deleteWorkspace(_ workspace: Workspace) async throws
}

@MainActor
protocol ServerSyncRepository: WorkspaceDeletionMutationEnqueuing, AnyObject {
    func pendingServerMutations() -> [ServerPendingMutation]
    func clearPendingServerAndWorkspaceMutations()
    func removePendingServerMutation(_ mutationID: UUID)
    func enqueueServerUpsert(_ server: Server)
    func enqueueServerDelete(_ server: Server)
    func enqueueWorkspaceUpsert(_ workspace: Workspace)
    func enqueueWorkspaceDelete(_ workspace: Workspace)
    func drainPendingMutations() async
}

@MainActor
protocol ServerManagerCredentialRepository: WorkspaceDeletionCredentialCleaning, AnyObject {
    func deleteCredentials(for serverId: UUID) throws
}

nonisolated enum ServerProtectedAction: Equatable, Sendable {
    case delete
}

@MainActor
protocol ProtectedServerActionAuthorizing: AnyObject {
    func authorize(
        _ server: Server,
        for action: ServerProtectedAction
    ) async -> Bool
}

@MainActor
protocol ServerKnownHostRepository: AnyObject {
    func remove(host: String, port: Int)
}

@MainActor
protocol FreePlanAssignmentTracking: AnyObject {
    func trackFreePlanGenerationAssigned(
        generation: String,
        serverCount: Int,
        reason: String
    )
}

@MainActor
struct ServerManagerDependencies {
    let stateStore: ServerStateStore
    let remoteRepository: any ServerRemoteRepository
    let syncRepository: any ServerSyncRepository
    let credentialRepository: any ServerManagerCredentialRepository
    let actionAuthorizer: any ProtectedServerActionAuthorizing
    let knownHosts: any ServerKnownHostRepository
    let isRemoteSchemaError: (Error) -> Bool
    let now: () -> Date
    let makeID: () -> UUID
}
