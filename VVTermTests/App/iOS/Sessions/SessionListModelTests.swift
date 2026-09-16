#if os(iOS)
import Testing
import Foundation
@testable import VVTerm

@MainActor
struct SessionListModelTests {
    @Test func endedShellNeverClaimsToResume() {
        var pane = TerminalPaneState(paneId: UUID(), tabId: UUID(), serverId: UUID())
        pane.connectionState = .disconnected
        pane.disconnectReason = .sessionEnded
        #expect(SessionConnectionStatus(pane: pane, hasResumeCheckpoint: true) == .ended)
        pane.disconnectReason = .transportInterrupted
        #expect(SessionConnectionStatus(pane: pane, hasResumeCheckpoint: false) == .ended)
        pane.remoteSessionStatus = .background
        #expect(SessionConnectionStatus(pane: pane, hasResumeCheckpoint: false) == .resumable)
    }

    @Test func mixedPanesDoNotHideFailure() {
        let serverID = UUID()
        let tab = TerminalTab(serverId: serverID, title: "Split")
        var good = TerminalPaneState(paneId: UUID(), tabId: tab.id, serverId: serverID)
        good.connectionState = .connected
        var ended = TerminalPaneState(paneId: UUID(), tabId: tab.id, serverId: serverID)
        ended.connectionState = .failed(.reconnectTimedOut)
        let statuses = [good, ended].map { SessionConnectionStatus(pane: $0, hasResumeCheckpoint: false) }
        #expect(statuses.first == .connected)
        guard case .failed = statuses.last else { Issue.record("Failure must remain visible"); return }
    }

    @Test func rowsKeepOrderAndSelectOrCloseOnlyTheRequestedTab() throws {
        let manager = TerminalTestComposition.makeManager()
        let suite = "sessions-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = RemoteFileTabManager(defaults: defaults)
        let browser = RemoteFileBrowserStore(defaults: defaults)
        let actions = SessionListActions(tabManager: manager, fileTabs: files, fileBrowser: browser)
        let server = Server(workspaceId: UUID(), name: "Server", host: "localhost", username: "test")
        let first = TerminalTab(serverId: server.id, title: server.name, createdAt: Date(timeIntervalSince1970: 1))
        let second = TerminalTab(serverId: server.id, title: server.name, createdAt: Date(timeIntervalSince1970: 2))
        for tab in [first, second] {
            manager.sessionState.install(tab, paneState: TerminalPaneState(paneId: tab.rootPaneId, tabId: tab.id, serverId: server.id), select: true)
        }
        let file = try #require(files.openTab(for: server, seedPath: "/tmp", hasProAccess: true))
        let rows = SessionListEntry.entries(server: server, tabManager: manager, fileTabs: files, fileBrowser: browser)
        #expect(rows.map(\.id.tabID) == [first.id, second.id, file.id])
        #expect(rows[0].title == LocalizedFormat.string("Terminal tab %lld", Int64(1)))
        #expect(rows[1].title == LocalizedFormat.string("Terminal tab %lld", Int64(2)))
        #expect(rows[0].badges == ["SSH"])
        #expect(rows[2].badges.isEmpty)
        manager.titleStore.setRuntimeTitle("A changed title", for: second.rootPaneId)
        #expect(SessionListEntry.entries(server: server, tabManager: manager, fileTabs: files, fileBrowser: browser).map(\.id) == rows.map(\.id))
        #expect(SessionListEntry.entries(server: server, tabManager: manager, fileTabs: files, fileBrowser: browser)[1].title == "A changed title")
        #expect(actions.select(rows[0].id))
        #expect(manager.sessionState.selectedTabId(for: server.id) == first.id)
        #expect(actions.select(rows[2].id))
        #expect(manager.connectionViewSelections.selection(for: server.id) == .files)
        #expect(files.selectedTab(for: server.id)?.id == file.id)
        actions.close(rows[2].id)
        #expect(files.tabs(for: server.id).isEmpty)
        #expect(manager.sessionState.tabs(for: server.id).count == 2)
        #expect(!actions.select(rows[2].id))
        actions.close(rows[0].id)
        #expect(manager.sessionState.tabs(for: server.id).map(\.id) == [second.id])
    }

    @Test func badgesKeepTransportAndPersistentBackendWithoutDuplicates() {
        let pane = SessionListEntry.Pane(id: UUID(), title: "Shell", status: .connected,
                                        transport: .mosh, remoteSession: "zmx", persistentBackend: "zmx")
        let entry = SessionListEntry(id: .terminal(serverID: UUID(), tabID: UUID()), title: "Shell",
                                    createdAt: .now, panes: [pane, pane], fileStatus: nil, path: nil)
        #expect(entry.badges == ["Mosh", "zmx"])
        let fallback = SessionListEntry.Pane(id: UUID(), title: "Shell", status: .connected,
                                            transport: .sshFallback, remoteSession: "off")
        #expect(fallback.transportLabel == "SSH")
    }

    @Test func destinationsKeepTabKindAndServerIdentity() {
        let server = UUID(), tab = UUID()
        #expect(SessionDestination.terminal(serverID: server, tabID: tab) != .files(serverID: server, tabID: tab))
        #expect(SessionDestination.files(serverID: server, tabID: tab).serverID == server)
        #expect(SessionDestination.terminal(serverID: server, tabID: tab).view == .terminal)
    }
}
#endif
