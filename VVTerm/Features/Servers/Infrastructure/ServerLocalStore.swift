import Foundation

@MainActor
struct ServerLocalStore {
    private static let workspaceDeletionJournalKey = "com.vivy.vvterm.workspaceDeletionJournal.v1"

    private let defaults: UserDefaults
    private let serversKey: String
    private let workspacesKey: String

    init(
        defaults: UserDefaults,
        serversKey: String = CloudKitSyncConstants.serverStorageKey,
        workspacesKey: String = CloudKitSyncConstants.workspaceStorageKey
    ) {
        self.defaults = defaults
        self.serversKey = serversKey
        self.workspacesKey = workspacesKey
    }

    func loadServers() -> ServerLocalLoadResult<[Server]> {
        if let plan = try? loadWorkspaceDeletionJournal()?.plan {
            return .loaded(plan.remainingServers)
        }
        return load([Server].self, forKey: serversKey, collection: .servers)
    }

    func loadWorkspaces() -> ServerLocalLoadResult<[Workspace]> {
        if let plan = try? loadWorkspaceDeletionJournal()?.plan {
            return .loaded(plan.remainingWorkspaces)
        }
        return load([Workspace].self, forKey: workspacesKey, collection: .workspaces)
    }

    func storeServers(_ servers: [Server]) throws {
        try store(servers, forKey: serversKey)
    }

    func storeWorkspaces(_ workspaces: [Workspace]) throws {
        try store(workspaces, forKey: workspacesKey)
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String,
        collection: ServerLocalStorageIssue.Collection
    ) -> ServerLocalLoadResult<Value> {
        guard let data = defaults.data(forKey: key) else {
            return .missing
        }

        do {
            return .loaded(try JSONDecoder().decode(type, from: data))
        } catch {
            let quarantineKey = quarantineKey(for: key)
            if defaults.data(forKey: quarantineKey) == nil {
                defaults.set(data, forKey: quarantineKey)
            }
            return .unreadable(
                ServerLocalStorageIssue(
                    collection: collection,
                    quarantineKey: quarantineKey
                )
            )
        }
    }

    private func store<Value: Encodable>(_ value: Value, forKey key: String) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }

    private func quarantineKey(for storageKey: String) -> String {
        "\(storageKey).unreadable-backup.v1"
    }
}

extension ServerLocalStore: ServerLocalRepository {
    func loadSnapshot() -> ServerLocalRepositorySnapshot {
        ServerLocalRepositorySnapshot(
            servers: loadServers(),
            workspaces: loadWorkspaces()
        )
    }

    func persist(servers: [Server], workspaces: [Workspace]) throws {
        let encoder = JSONEncoder()
        let serverData = try encoder.encode(servers)
        let workspaceData = try encoder.encode(workspaces)
        let previousServerData = defaults.data(forKey: serversKey)
        let previousWorkspaceData = defaults.data(forKey: workspacesKey)

        defaults.set(serverData, forKey: serversKey)
        defaults.set(workspaceData, forKey: workspacesKey)
        guard defaults.data(forKey: serversKey) == serverData,
              defaults.data(forKey: workspacesKey) == workspaceData else {
            restore(previousServerData, forKey: serversKey)
            restore(previousWorkspaceData, forKey: workspacesKey)
            throw ServerLocalStoreError.persistenceFailed
        }
    }

    func clearServerData() {
        defaults.removeObject(forKey: serversKey)
        defaults.removeObject(forKey: workspacesKey)
    }

    private func restore(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private enum ServerLocalStoreError: Error {
    case persistenceFailed
}

extension ServerLocalStore: WorkspaceDeletionJournalStoring {
    func loadWorkspaceDeletionJournal() throws -> WorkspaceDeletionJournal? {
        guard let data = defaults.data(forKey: Self.workspaceDeletionJournalKey) else {
            return nil
        }
        return try JSONDecoder().decode(WorkspaceDeletionJournal.self, from: data)
    }

    func storeWorkspaceDeletionJournal(_ journal: WorkspaceDeletionJournal) throws {
        defaults.set(
            try JSONEncoder().encode(journal),
            forKey: Self.workspaceDeletionJournalKey
        )
    }

    func materializeWorkspaceDeletion(_ plan: WorkspaceDeletionPlan) throws {
        try persist(
            servers: plan.remainingServers,
            workspaces: plan.remainingWorkspaces
        )
    }

    func clearWorkspaceDeletionJournal() throws {
        defaults.removeObject(forKey: Self.workspaceDeletionJournalKey)
    }
}
