#if os(iOS)
import Foundation

/// App-level actions coordinate terminal and Files owners without changing their models.
@MainActor
struct SessionListActions {
    let tabManager: TerminalTabManager
    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore

    /// Select existing state only. Stale list rows must never create a replacement session.
    @discardableResult
    func select(_ destination: SessionDestination) -> Bool {
        switch destination {
        case .terminal(let serverID, let tabID):
            guard tabManager.sessionState.tabs(for: serverID).contains(where: { $0.id == tabID }) else { return false }
            tabManager.sessionState.selectTab(tabID, for: serverID)
        case .files(let serverID, let tabID):
            guard let tab = fileTabs.tabs(for: serverID).first(where: { $0.id == tabID }) else { return false }
            fileTabs.selectTab(tab)
        }
        tabManager.sessionState.selectView(destination.view, for: destination.serverID)
        return true
    }

    func close(_ destination: SessionDestination) {
        switch destination {
        case .terminal(let serverID, let tabID):
            if let tab = tabManager.sessionState.tabs(for: serverID).first(where: { $0.id == tabID }) {
                tabManager.closeTab(tab)
            }
        case .files(let serverID, let tabID):
            if let tab = fileTabs.tabs(for: serverID).first(where: { $0.id == tabID }),
               let removed = fileTabs.closeTab(tab) {
                fileBrowser.removeState(for: removed.id)
            }
        }
    }

    func disconnect(serverID: UUID) {
        fileBrowser.disconnect(serverId: serverID)
        fileTabs.disconnect(serverId: serverID)
        tabManager.disconnectServer(serverID)
    }
}
#endif
