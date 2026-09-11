import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalNotificationNavigationStoreTests: TerminalTabManagerTestSupport {
    @Test
    func notificationSelectsTerminalTabAndSourceSplitPane() async throws {
        let manager = TerminalTestComposition.makeManager()
        let server = makeServer()
        let source = TerminalTab(serverId: server.id, title: "Source")
        installTab(source, in: manager)
        let pane = try #require(manager.sessionState.createSplitPane(
            in: source, paneId: source.rootPaneId, placement: .right, remoteSessionStatus: .off
        ))
        manager.focusPane(in: source, paneId: source.rootPaneId)
        let other = TerminalTab(serverId: server.id, title: "Other")
        installTab(other, in: manager)
        manager.sessionState.selectView(.files, for: server.id)
        let navigation = TerminalNotificationNavigationStore(
            tabManager: manager, serverProvider: { $0 == server.id ? server : nil }, unlockServer: { _ in true }
        )
        let context = TerminalNotificationContext(paneId: pane, tabId: source.id, serverId: server.id)
        navigation.request(context)
        #expect(await navigation.resolve(context) == server)
        #expect(manager.sessionState.selectedTabId(for: server.id) == source.id)
        #expect(manager.sessionState.tab(id: source.id, for: server.id)?.focusedPaneId == pane)
        #expect(manager.connectionViewSelections.selection(for: server.id) == .terminal)
        navigation.consume(context)
        #expect(navigation.pending == nil)
        // A later tap on the same notification can route again.
        navigation.request(context)
        #expect(await navigation.resolve(context) == server)
        await manager.resetForTesting()
    }

    @Test
    func invalidDestinationsDoNotOpenOrAuthenticate() async {
        let manager = TerminalTestComposition.makeManager()
        let server = makeServer()
        let tab = TerminalTab(serverId: server.id, title: "Source")
        installTab(tab, in: manager)
        var unlocks = 0
        let navigation = TerminalNotificationNavigationStore(
            tabManager: manager, serverProvider: { $0 == server.id ? server : nil },
            unlockServer: { _ in unlocks += 1; return true }
        )
        for context in [
            TerminalNotificationContext(paneId: UUID(), tabId: tab.id, serverId: server.id),
            .init(paneId: tab.rootPaneId, tabId: UUID(), serverId: server.id),
            .init(paneId: tab.rootPaneId, tabId: tab.id, serverId: UUID())
        ] {
            navigation.request(context)
            #expect(await navigation.resolve(context) == nil)
            #expect(navigation.pending == nil)
        }
        #expect(unlocks == 0)
        #expect(manager.sessionState.tabs(for: server.id).count == 1)
        await manager.resetForTesting()
    }

    @Test
    func deniedUnlockPreservesCurrentTab() async {
        let manager = TerminalTestComposition.makeManager()
        let server = makeServer()
        let source = TerminalTab(serverId: server.id, title: "Source")
        let other = TerminalTab(serverId: server.id, title: "Other")
        installTab(source, in: manager)
        installTab(other, in: manager)
        let navigation = TerminalNotificationNavigationStore(
            tabManager: manager, serverProvider: { _ in server }, unlockServer: { _ in false }
        )
        let context = TerminalNotificationContext(paneId: source.rootPaneId, tabId: source.id, serverId: server.id)
        navigation.request(context)
        #expect(await navigation.resolve(context) == nil)
        #expect(navigation.pending == nil)
        #expect(manager.sessionState.selectedTabId(for: server.id) == other.id)
        await manager.resetForTesting()
    }

    enum AuthenticationChange: CaseIterable { case replace, close, cancel, edit }

    @Test(arguments: AuthenticationChange.allCases)
    func revalidatesAfterAuthentication(change: AuthenticationChange) async {
        let manager = TerminalTestComposition.makeManager()
        var server = makeServer()
        let tab = TerminalTab(serverId: server.id, title: "Source")
        installTab(tab, in: manager)
        var continuation: CheckedContinuation<Bool, Never>?
        let navigation = TerminalNotificationNavigationStore(
            tabManager: manager, serverProvider: { _ in server },
            unlockServer: { _ in await withCheckedContinuation { continuation = $0 } }
        )
        let context = TerminalNotificationContext(paneId: tab.rootPaneId, tabId: tab.id, serverId: server.id)
        navigation.request(context)
        let task = Task { await navigation.resolve(context) }
        while continuation == nil { await Task.yield() }
        let replacement = TerminalNotificationContext(paneId: UUID(), tabId: UUID(), serverId: UUID())
        switch change {
        case .replace: navigation.request(replacement)
        case .close: _ = manager.sessionState.removeTab(tab)
        case .cancel: task.cancel()
        case .edit: server.requiresBiometricUnlock = true
        }
        continuation?.resume(returning: true)
        #expect(await task.value == nil)
        if change == .replace { #expect(navigation.pending == replacement) }
        if change == .cancel { #expect(navigation.pending == context) }
        await manager.resetForTesting()
    }
}
