import Combine
import Foundation

extension RemoteFileBrowserStore {
    func loadPersistedStates() {
        if defaults.object(forKey: legacyPersistenceKey) != nil {
            defaults.removeObject(forKey: legacyPersistenceKey)
        }

        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: RemoteFileBrowserPersistedState].self, from: data) else {
            persistedStates = [:]
            return
        }
        persistedStates = decoded
    }

    func persistedState(for tabId: UUID) -> RemoteFileBrowserPersistedState {
        persistedStates[tabId.uuidString] ?? .init()
    }

    func persistState(for tabId: UUID) {
        let fallback = persistedState(for: tabId)
        let state = states[tabId]
        persistedStates[tabId.uuidString] = RemoteFileBrowserPersistedState(
            lastVisitedPath: state?.currentPath ?? fallback.lastVisitedPath,
            sort: state?.sort ?? fallback.sort,
            sortDirection: state?.sortDirection ?? fallback.sortDirection,
            showHiddenFiles: state?.showHiddenFiles ?? fallback.showHiddenFiles,
            hasCustomizedHiddenFiles: state?.hasCustomizedHiddenFiles ?? fallback.hasCustomizedHiddenFiles
        )
        persistStates()
    }

    func persistStates() {
        guard let data = try? JSONEncoder().encode(persistedStates) else { return }
        defaults.set(data, forKey: persistenceKey)
    }
}
