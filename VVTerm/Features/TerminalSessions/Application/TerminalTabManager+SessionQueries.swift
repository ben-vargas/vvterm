import Foundation

extension TerminalTabManager {
    /// Get tabs for a server
    func tabs(for serverId: UUID) -> [TerminalTab] {
        sessionState.tabs(for: serverId)
    }

    /// Get currently selected tab for a server
    func selectedTab(for serverId: UUID) -> TerminalTab? {
        sessionState.selectedTab(for: serverId)
    }

    func selectedTabId(for serverId: UUID) -> UUID? {
        sessionState.selectedTabId(for: serverId)
    }

    func selectedView(for serverId: UUID) -> ConnectionViewTabID? {
        connectionViewSelections.selection(for: serverId)
    }

    func paneState(for paneId: UUID) -> TerminalPaneState? {
        sessionState.paneState(for: paneId)
    }

    func serverIdsWithTabs() -> Set<UUID> {
        sessionState.serverIdsWithTabs
    }
}
