import Foundation

nonisolated enum ServerFormIntent: Equatable, Hashable, Identifiable, Sendable {
    case create(prefill: ServerFormPrefill?)
    case edit(Server)
    case duplicate(Server)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let server):
            return "edit-\(server.id.uuidString)"
        case .duplicate(let server):
            return "duplicate-\(server.id.uuidString)"
        }
    }

    var sourceServer: Server? {
        switch self {
        case .create:
            return nil
        case .edit(let server), .duplicate(let server):
            return server
        }
    }

    var editedServer: Server? {
        guard case .edit(let server) = self else { return nil }
        return server
    }

    var prefill: ServerFormPrefill? {
        guard case .create(let prefill) = self else { return nil }
        return prefill
    }

    var isEditing: Bool {
        editedServer != nil
    }

    func serverID(makeID: () -> UUID) -> UUID {
        editedServer?.id ?? makeID()
    }

    func createdAt(now: () -> Date) -> Date {
        editedServer?.createdAt ?? now()
    }

    func mutation(for server: Server) -> ServerMutation {
        isEditing ? .update(server) : .create(server)
    }

    func preservingSourceMetadata(in server: Server) -> Server {
        guard let sourceServer else { return server }

        var result = server
        result.tags = sourceServer.tags
        result.isFavorite = sourceServer.isFavorite
        if isEditing {
            result.lastConnected = sourceServer.lastConnected
        }
        return result
    }
}
