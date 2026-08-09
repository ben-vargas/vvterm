import Foundation

enum WorkspaceSelectionPolicy {
    static func workspace(
        current: Workspace?,
        available: [Workspace]
    ) -> Workspace? {
        guard let current else { return available.first }
        return available.first { $0.id == current.id } ?? available.first
    }

    static func environment(
        current: ServerEnvironment?,
        workspace: Workspace?
    ) -> ServerEnvironment? {
        guard let current, let workspace else { return nil }
        return workspace.environment(withId: current.id)
    }

    static func environmentFilterIDs(
        stored: String,
        workspace: Workspace?
    ) -> Set<UUID> {
        guard let workspace else { return [] }
        let selections = decodedEnvironmentFilters(stored)
        let selected = Set(selections[workspace.id.uuidString] ?? [])
        return selected.intersection(workspace.environments.map(\.id))
    }

    static func updatingEnvironmentFilterIDs(
        _ selected: Set<UUID>,
        for workspace: Workspace?,
        stored: String
    ) -> String {
        guard let workspace else { return stored }

        var selections = decodedEnvironmentFilters(stored)
        let available = Set(workspace.environments.map(\.id))
        let normalized = selected.intersection(available)
        let key = workspace.id.uuidString

        if normalized.isEmpty || normalized == available {
            selections.removeValue(forKey: key)
        } else {
            selections[key] = normalized.sorted { $0.uuidString < $1.uuidString }
        }

        return encodedEnvironmentFilters(selections)
    }

    static func reconciledEnvironmentFilters(
        stored: String,
        workspaces: [Workspace]
    ) -> String {
        let availableByWorkspace = Dictionary(
            uniqueKeysWithValues: workspaces.map { workspace in
                (workspace.id.uuidString, Set(workspace.environments.map(\.id)))
            }
        )
        let reconciled = decodedEnvironmentFilters(stored).reduce(into: [String: [UUID]]()) { result, item in
            guard let available = availableByWorkspace[item.key] else { return }
            let normalized = Set(item.value).intersection(available)
            guard !normalized.isEmpty, normalized != available else { return }
            result[item.key] = normalized.sorted { $0.uuidString < $1.uuidString }
        }
        return encodedEnvironmentFilters(reconciled)
    }

    static func migratingLegacyEnvironmentFilters(
        _ legacy: String,
        to workspace: Workspace?,
        stored: String
    ) -> String {
        guard stored.isEmpty, !legacy.isEmpty else { return stored }
        let selected = Set(
            legacy
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
        )
        return updatingEnvironmentFilterIDs(selected, for: workspace, stored: stored)
    }

    private static func decodedEnvironmentFilters(_ stored: String) -> [String: [UUID]] {
        guard let data = stored.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [UUID]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func encodedEnvironmentFilters(_ filters: [String: [UUID]]) -> String {
        guard !filters.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(filters) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
