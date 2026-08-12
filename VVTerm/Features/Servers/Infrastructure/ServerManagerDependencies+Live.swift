import Foundation

extension CloudKitSyncCoordinator: ServerSyncRepository {
    func clearPendingServerAndWorkspaceMutations() throws {
        try removeAll { ServerPendingCloudKitPayloadCodec.contains($0.payload) }
    }

    func enqueueServerUpsert(_ server: Server) throws {
        try enqueue(.serverUpsert(server))
    }

    func enqueueServerDelete(_ server: Server) throws {
        try enqueue(.serverDelete(server))
    }

    func enqueueServerMutation(_ mutation: ServerPendingMutation) throws {
        try enqueueAtomically([try PendingCloudKitMutation(mutation)])
    }

    func enqueueWorkspaceUpsert(_ workspace: Workspace) throws {
        try enqueue(.workspaceUpsert(workspace))
    }

    func enqueueWorkspaceDelete(_ workspace: Workspace) throws {
        try enqueue(.workspaceDelete(workspace))
    }

    func pendingServerMutations() -> [ServerPendingMutation] {
        snapshot().compactMap(ServerPendingMutation.init)
    }

    func removePendingServerMutation(_ mutationID: UUID) throws {
        try remove(mutationID)
    }

    func enqueueWorkspaceDeletionMutations(_ mutations: [ServerPendingMutation]) throws {
        guard mutations.allSatisfy(\.payload.isDeletion) else {
            throw WorkspaceDeletionTransactionError.invalidPendingMutation
        }
        try enqueueAtomically(try mutations.map(PendingCloudKitMutation.init))
    }

    func enqueueEnvironmentDeletionMutations(_ mutations: [ServerPendingMutation]) throws {
        let isEnvironmentUpdate = mutations.allSatisfy { mutation in
            switch mutation.payload {
            case .serverUpsert, .workspaceUpsert:
                true
            case .serverDelete, .workspaceDelete:
                false
            }
        }
        guard isEnvironmentUpdate else {
            throw EnvironmentDeletionTransactionError.invalidPendingMutation
        }
        try enqueueAtomically(try mutations.map(PendingCloudKitMutation.init))
    }
}

extension KeychainManager: ServerManagerCredentialRepository {
    func cleanupCredentials(for server: Server) throws {
        try deleteCredentials(for: server.id)
        guard try !hasCredentials(for: server) else {
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
        defaults: UserDefaults,
        serverCloud: ServerCloudKitClient,
        credentialRepository: any ServerManagerCredentialRepository,
        knownHosts: any ServerKnownHostRepository,
        freePlanTracker: any FreePlanAssignmentTracking,
        actionAuthorizer: any ProtectedServerActionAuthorizing,
        syncRepository: any ServerSyncRepository,
        defaultWorkspaceName: @escaping () -> String,
        canonicalDefaultWorkspaceNames: @escaping () -> Set<String>,
        now: @escaping () -> Date,
        makeID: @escaping () -> UUID
    ) -> Self {
        let stateStore = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: ServerLocalStore(defaults: defaults),
                preferences: ServerManagerUserDefaultsPreferences(defaults: defaults),
                freePlanTracker: freePlanTracker,
                isSyncEnabled: { SyncSettings.isEnabled(in: defaults) },
                now: now,
                makeID: makeID,
                defaultWorkspaceName: defaultWorkspaceName,
                canonicalDefaultWorkspaceNames: canonicalDefaultWorkspaceNames
            )
        )
        return Self(
            stateStore: stateStore,
            remoteRepository: serverCloud,
            syncRepository: syncRepository,
            credentialRepository: credentialRepository,
            actionAuthorizer: actionAuthorizer,
            knownHosts: knownHosts,
            isRemoteSchemaError: ServerCloudKitClient.isSchemaError,
            now: now,
            makeID: makeID
        )
    }
}

private extension ServerPendingMutation {
    init?(_ mutation: PendingCloudKitMutation) {
        guard let payload = try? ServerPendingCloudKitPayloadCodec.decode(mutation.payload) else {
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
    init(_ mutation: ServerPendingMutation) throws {
        self.init(
            id: mutation.id,
            payload: try ServerPendingCloudKitPayloadCodec.encode(mutation.payload),
            createdAt: mutation.createdAt
        )
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

private enum EnvironmentDeletionTransactionError: LocalizedError {
    case invalidPendingMutation

    var errorDescription: String? {
        String(localized: "The environment deletion sync transaction is invalid.")
    }
}
