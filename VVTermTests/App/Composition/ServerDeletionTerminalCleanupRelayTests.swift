import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerDeletionTerminalCleanupRelayTests: TerminalTabManagerTestSupport {
    @Test
    func boundRelayDisconnectsPersistedTabsForDeletedServer() async {
        let manager = TerminalTestComposition.makeManager()
        let deletedServerID = UUID()
        let retainedServerID = UUID()
        installTab(
            TerminalTab(serverId: deletedServerID, title: "Deleted"),
            in: manager
        )
        installTab(
            TerminalTab(serverId: retainedServerID, title: "Retained"),
            in: manager
        )
        let relay = ServerDeletionTerminalCleanupRelay()

        relay.bind(to: manager)
        relay.handleServerDeletion(deletedServerID)

        #expect(manager.sessionState.tabs(for: deletedServerID).isEmpty)
        #expect(manager.sessionState.tabs(for: retainedServerID).count == 1)
        await manager.resetForTesting()
    }
}
