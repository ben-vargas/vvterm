import Foundation

/// Breaks the production initialization cycle between server state and terminal state.
@MainActor
final class ServerDeletionTerminalCleanupRelay {
    private weak var tabManager: TerminalTabManager?

    func bind(to tabManager: TerminalTabManager) {
        self.tabManager = tabManager
    }

    func handleServerDeletion(_ serverID: UUID) {
        tabManager?.disconnectServer(serverID)
    }
}
