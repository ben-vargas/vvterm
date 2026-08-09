import Foundation

nonisolated struct ServerLocalStorageIssue: Identifiable, Equatable, Sendable {
    nonisolated enum Collection: String, Equatable, Sendable {
        case servers
        case workspaces
    }

    let collection: Collection
    let quarantineKey: String

    var id: Collection { collection }
}

nonisolated enum ServerLocalLoadResult<Value> {
    case missing
    case loaded(Value)
    case unreadable(ServerLocalStorageIssue)
}

@MainActor
struct ServerLocalStore {
    private let defaults: UserDefaults
    private let serversKey: String
    private let workspacesKey: String

    init(
        defaults: UserDefaults = .standard,
        serversKey: String = CloudKitSyncConstants.serverStorageKey,
        workspacesKey: String = CloudKitSyncConstants.workspaceStorageKey
    ) {
        self.defaults = defaults
        self.serversKey = serversKey
        self.workspacesKey = workspacesKey
    }

    func loadServers() -> ServerLocalLoadResult<[Server]> {
        load([Server].self, forKey: serversKey, collection: .servers)
    }

    func loadWorkspaces() -> ServerLocalLoadResult<[Workspace]> {
        load([Workspace].self, forKey: workspacesKey, collection: .workspaces)
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
