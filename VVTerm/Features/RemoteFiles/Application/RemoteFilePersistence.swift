import Foundation

extension RemoteFileBrowserStore {
    func loadPersistedStates() {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: RemoteFileBrowserPersistedState].self, from: data) else {
            persistedStates = [:]
            return
        }
        persistedStates = decoded
    }

    func persistedState(for serverId: UUID) -> RemoteFileBrowserPersistedState {
        persistedStates[serverId.uuidString] ?? .init()
    }

    func persistState(for serverId: UUID) {
        let state = states[serverId] ?? BrowserState(persisted: persistedState(for: serverId))
        persistedStates[serverId.uuidString] = RemoteFileBrowserPersistedState(
            lastVisitedPath: state.currentPath,
            sort: state.sort,
            sortDirection: state.sortDirection,
            showHiddenFiles: state.showHiddenFiles,
            hasCustomizedHiddenFiles: state.hasCustomizedHiddenFiles
        )

        guard let data = try? JSONEncoder().encode(persistedStates) else { return }
        defaults.set(data, forKey: persistenceKey)
    }
}
