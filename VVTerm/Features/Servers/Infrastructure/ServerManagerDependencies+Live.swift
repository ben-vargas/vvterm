import Foundation

@MainActor
enum ServerCloudKitLiveComposition {
    static let client = ServerCloudKitClient(
        transport: CloudKitManager.shared,
        now: Date.init
    )
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
    static func live(
        actionAuthorizer: any ProtectedServerActionAuthorizing,
        syncRepository: any ServerSyncRepository
    ) -> Self {
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
        return Self(
            stateStore: stateStore,
            remoteRepository: ServerCloudKitLiveComposition.client,
            syncRepository: syncRepository,
            credentialRepository: KeychainManager.shared,
            actionAuthorizer: actionAuthorizer,
            knownHosts: KnownHostsManager.shared,
            isRemoteSchemaError: ServerCloudKitClient.isSchemaError,
            now: Date.init,
            makeID: UUID.init
        )
    }
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
