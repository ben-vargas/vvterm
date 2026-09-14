import Combine
import Foundation

/// Keeps a notification destination until an active app window can handle it.
@MainActor
final class TerminalNotificationNavigationStore: ObservableObject {
    enum Destination: Equatable {
        case app
        case terminal(Server)
    }

    @Published private(set) var pending: TerminalNotificationContext?
    private let tabManager: TerminalTabManager
    private let serverProvider: (UUID) -> Server?
    private let unlockServer: (Server) async -> Bool

    init(
        tabManager: TerminalTabManager,
        serverProvider: @escaping (UUID) -> Server?,
        unlockServer: @escaping (Server) async -> Bool
    ) {
        self.tabManager = tabManager
        self.serverProvider = serverProvider
        self.unlockServer = unlockServer
    }

    func request(_ context: TerminalNotificationContext) {
        pending = context
    }

    func consume(_ context: TerminalNotificationContext) {
        if pending == context { pending = nil }
    }

    /// The presenting view owns cancellation of this work through its SwiftUI task.
    func resolve(_ context: TerminalNotificationContext) async -> Destination? {
        guard pending == context else { return nil }
        guard let server = serverProvider(context.serverId), validTab(for: context) != nil else {
            return .app
        }
        let allowed = await unlockServer(server)
        guard !Task.isCancelled, pending == context else { return nil }
        // Authentication may outlive a closed pane or an edited/deleted server.
        guard allowed else {
            consume(context)
            return nil
        }
        guard serverProvider(context.serverId) == server,
              let tab = validTab(for: context) else { return .app }
        tabManager.sessionState.selectView(.terminal, for: server.id)
        tabManager.sessionState.selectTab(tab.id, for: server.id)
        tabManager.focusPane(in: tab, paneId: context.paneId)
        return .terminal(server)
    }

    private func validTab(for context: TerminalNotificationContext) -> TerminalTab? {
        guard let tab = tabManager.sessionState.tab(id: context.tabId, for: context.serverId),
              tab.allPaneIds.contains(context.paneId) else { return nil }
        return tab
    }
}
