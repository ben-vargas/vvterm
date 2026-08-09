import Foundation

extension CloudKitManager: ServerRemoteRepository {
    func fetchServerChanges(forceFullFetch: Bool) async throws -> ServerRemoteChanges {
        let changes = try await fetchChanges(forceFullFetch: forceFullFetch)
        return ServerRemoteChanges(
            servers: changes.servers,
            workspaces: changes.workspaces,
            deletedServerIDs: changes.deletedServerIDs,
            deletedWorkspaceIDs: changes.deletedWorkspaceIDs,
            isFullFetch: changes.isFullFetch
        )
    }
}

extension CloudKitSyncCoordinator: ServerSyncRepository {
    func pendingServerMutations() -> [ServerPendingMutation] {
        snapshot().compactMap(ServerPendingMutation.init)
    }

    func removePendingServerMutation(_ mutationID: UUID) {
        removePendingMutation(mutationID)
    }

    func enqueueWorkspaceDeletionMutations(_ mutations: [ServerPendingMutation]) throws {
        guard mutations.allSatisfy(\.payload.isDeletion) else {
            throw WorkspaceDeletionTransactionError.invalidPendingMutation
        }
        try enqueueMutationsAtomically(mutations.map(PendingCloudKitMutation.init))
    }
}

extension KeychainManager: ServerManagerCredentialRepository {
    func cleanupCredentials(for server: Server) throws {
        try deleteCredentials(for: server.id)
        guard try credentialBindingStatus(for: server) == .noCredentials else {
            throw WorkspaceDeletionTransactionError.credentialCleanupIncomplete
        }
    }
}
extension AppLockManager: ProtectedServerActionAuthorizing {
    func authorize(_ server: Server, for action: ServerProtectedAction) async -> Bool {
        switch action {
        case .delete:
            return await authorizeProtectedServerAction(server, action: .delete)
        }
    }
}
extension KnownHostsManager: ServerKnownHostRepository {}
extension AnalyticsTracker: FreePlanAssignmentTracking {}

extension ServerManagerDependencies {
    static var live: Self {
        let stateStore = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: ServerLocalStore(),
                preferences: ServerManagerUserDefaultsPreferences(),
                freePlanTracker: AnalyticsTracker.shared,
                isSyncEnabled: { SyncSettings.isEnabled },
                now: Date.init,
                makeID: UUID.init,
                defaultWorkspaceName: { AppLanguage.localizedString("My Servers") },
                canonicalDefaultWorkspaceNames: {
                    Set(AppLanguage.localizedValues(for: "My Servers"))
                }
            )
        )
        Self(
            stateStore: stateStore,
            remoteRepository: CloudKitManager.shared,
            syncRepository: CloudKitSyncCoordinator.shared,
            credentialRepository: KeychainManager.shared,
            actionAuthorizer: AppLockManager.shared,
            knownHosts: KnownHostsManager.shared,
            isRemoteSchemaError: CloudKitManager.isSchemaError,
            now: Date.init,
            makeID: UUID.init
        )
    }
}

extension ServerManager {
    static let shared = ServerManager(dependencies: .live)
}

private extension ServerPendingMutation {
    init?(_ mutation: PendingCloudKitMutation) {
        let payload: Payload
        switch mutation.payload {
        case .serverUpsert(let server):
            payload = .serverUpsert(server)
        case .serverDelete(let server):
            payload = .serverDelete(server)
        case .workspaceUpsert(let workspace):
            payload = .workspaceUpsert(workspace)
        case .workspaceDelete(let workspace):
            payload = .workspaceDelete(workspace)
        default:
            return nil
        }
        self.init(id: mutation.id, payload: payload, createdAt: mutation.createdAt)
    }
}

private extension ServerPendingMutation.Payload {
    var isDeletion: Bool {
        switch self {
        case .serverDelete, .workspaceDelete:
            return true
        case .serverUpsert, .workspaceUpsert:
            return false
        }
    }
}

private extension PendingCloudKitMutation {
    init(_ mutation: ServerPendingMutation) {
        let payload: PendingCloudKitMutationPayload
        switch mutation.payload {
        case .serverUpsert(let server):
            payload = .serverUpsert(server)
        case .serverDelete(let server):
            payload = .serverDelete(server)
        case .workspaceUpsert(let workspace):
            payload = .workspaceUpsert(workspace)
        case .workspaceDelete(let workspace):
            payload = .workspaceDelete(workspace)
        }
        self.init(id: mutation.id, payload: payload, createdAt: mutation.createdAt)
    }
}

private enum WorkspaceDeletionTransactionError: LocalizedError {
    case invalidPendingMutation
    case credentialCleanupIncomplete

    var errorDescription: String? {
        switch self {
        case .invalidPendingMutation:
            return "The workspace deletion contains an invalid pending mutation."
        case .credentialCleanupIncomplete:
            return "The server credentials are still present after cleanup."
        }
    }
}
