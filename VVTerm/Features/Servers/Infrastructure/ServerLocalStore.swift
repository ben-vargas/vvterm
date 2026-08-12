import Foundation

@MainActor
struct ServerLocalStore {
    static let serversStorageKey = "com.vivy.vvterm.servers"
    static let workspacesStorageKey = "com.vivy.vvterm.workspaces"
    private static let serverMutationTransactionJournalKey =
        "com.vivy.vvterm.serverMutationTransactionJournal.v1"
    private static let workspaceDeletionJournalKey = "com.vivy.vvterm.workspaceDeletionJournal.v1"
    private static let environmentDeletionJournalKey = "com.vivy.vvterm.environmentDeletionJournal.v1"

    private let defaults: UserDefaults
    private let serversKey: String
    private let workspacesKey: String

    init(
        defaults: UserDefaults,
        serversKey: String = Self.serversStorageKey,
        workspacesKey: String = Self.workspacesStorageKey
    ) {
        self.defaults = defaults
        self.serversKey = serversKey
        self.workspacesKey = workspacesKey
    }

    func loadServers() -> ServerLocalLoadResult<[Server]> {
        if let journal = try? loadServerMutationTransactionJournal() {
            return .loaded(
                journal.presentsResultingState
                    ? journal.plan.resultingServers
                    : journal.plan.previousServers
            )
        }
        if let plan = try? loadWorkspaceDeletionJournal()?.plan {
            return .loaded(plan.remainingServers)
        }
        if let plan = try? loadEnvironmentDeletionJournal()?.plan {
            return .loaded(plan.resultingServers)
        }
        return load([Server].self, forKey: serversKey, collection: .servers)
    }

    func loadWorkspaces() -> ServerLocalLoadResult<[Workspace]> {
        if let journal = try? loadServerMutationTransactionJournal() {
            return .loaded(
                journal.presentsResultingState
                    ? journal.plan.resultingWorkspaces
                    : journal.plan.previousWorkspaces
            )
        }
        if let plan = try? loadWorkspaceDeletionJournal()?.plan {
            return .loaded(plan.remainingWorkspaces)
        }
        if let plan = try? loadEnvironmentDeletionJournal()?.plan {
            return .loaded(plan.resultingWorkspaces)
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

extension ServerLocalStore: ServerMutationTransactionJournalStoring {
    func loadServerMutationTransactionJournal() throws -> ServerMutationTransactionJournal? {
        guard let data = defaults.data(forKey: Self.serverMutationTransactionJournalKey) else {
            return nil
        }
        return try JSONDecoder().decode(ServerMutationTransactionJournal.self, from: data)
    }

    func storeServerMutationTransactionJournal(
        _ journal: ServerMutationTransactionJournal
    ) throws {
        let data = try JSONEncoder().encode(journal)
        defaults.set(data, forKey: Self.serverMutationTransactionJournalKey)
        guard defaults.data(forKey: Self.serverMutationTransactionJournalKey) == data else {
            throw ServerLocalStoreError.persistenceFailed
        }
    }

    func materializeServerMutation(_ plan: ServerMutationTransactionPlan) throws {
        try persist(
            servers: plan.resultingServers,
            workspaces: plan.resultingWorkspaces
        )
    }

    func clearServerMutationTransactionJournal() throws {
        defaults.removeObject(forKey: Self.serverMutationTransactionJournalKey)
        guard defaults.object(forKey: Self.serverMutationTransactionJournalKey) == nil else {
            throw ServerLocalStoreError.persistenceFailed
        }
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

extension ServerLocalStore: EnvironmentDeletionJournalStoring {
    func loadEnvironmentDeletionJournal() throws -> EnvironmentDeletionJournal? {
        guard let data = defaults.data(forKey: Self.environmentDeletionJournalKey) else { return nil }
        return try JSONDecoder().decode(EnvironmentDeletionJournal.self, from: data)
    }

    func storeEnvironmentDeletionJournal(_ journal: EnvironmentDeletionJournal) throws {
        defaults.set(try JSONEncoder().encode(journal), forKey: Self.environmentDeletionJournalKey)
    }

    func materializeEnvironmentDeletion(_ plan: EnvironmentDeletionPlan) throws {
        try persist(servers: plan.resultingServers, workspaces: plan.resultingWorkspaces)
    }

    func clearEnvironmentDeletionJournal() throws {
        defaults.removeObject(forKey: Self.environmentDeletionJournalKey)
    }
}
