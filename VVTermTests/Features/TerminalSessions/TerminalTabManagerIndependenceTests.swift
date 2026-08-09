import CoreGraphics
import ETSession
import Foundation
import MoshCore
import Testing
@testable import VVTerm

@MainActor
private final class InMemoryTerminalTabSnapshotStore: TerminalTabSnapshotStoring {
    private(set) var data: Data?

    func loadSnapshotData() -> Data? {
        data
    }

    func saveSnapshotData(_ data: Data) {
        self.data = data
    }

    func removeSnapshotData() {
        data = nil
    }
}

private final class IsolatedEternalTerminalResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? { nil }
    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { false }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

private final class IsolatedMoshResumeStore: MoshResumeStoring {
    func snapshot(for paneId: UUID) throws -> MoshSnapshot? { nil }
    func hasSnapshot(for paneId: UUID) -> Bool { false }
    func save(_ snapshot: MoshSnapshot, for paneId: UUID) throws {}
    func deleteSnapshot(for paneId: UUID) throws {}
}

@Suite(.serialized)
@MainActor
struct TerminalTabManagerIndependenceTests {
    @Test
    func managersDoNotSharePaneShellTmuxOrTerminalRegistrations() async throws {
        let first = makeManager(snapshotStore: InMemoryTerminalTabSnapshotStore())
        let second = makeManager(snapshotStore: InMemoryTerminalTabSnapshotStore())
        let tab = TerminalTab(serverId: UUID(), title: "Independent runtime")
        install(tab, in: first)
        install(tab, in: second)

        let ghosttyApp = Ghostty.App()
        let appHandle = try #require(ghosttyApp.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: ghosttyApp,
            paneId: tab.rootPaneId.uuidString,
            useCustomIO: true
        )
        defer {
            first.unregisterTerminal(terminal, for: tab.rootPaneId)
            ghosttyApp.cleanup()
        }

        first.updatePaneState(tab.rootPaneId, connectionState: .connected)
        let client = SSHClient()
        let startToken = try #require(first.beginShellStart(for: tab.rootPaneId, client: client))
        #expect(await first.registerSSHClient(
            client,
            shellId: UUID(),
            startToken: startToken,
            for: tab.rootPaneId,
            serverId: tab.serverId
        ))
        first.tmuxResolver.sessionNames[tab.rootPaneId] = "vvterm-isolated"
        first.tmuxResolver.sessionOwnership[tab.rootPaneId] = .managed
        first.registerTerminal(terminal, for: tab.rootPaneId)

        #expect(first.paneState(for: tab.rootPaneId)?.connectionState == .connected)
        #expect(second.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
        #expect(first.getSSHClient(for: tab.rootPaneId) === client)
        #expect(second.getSSHClient(for: tab.rootPaneId) == nil)
        #expect(first.tmuxResolver.sessionNames[tab.rootPaneId] == "vvterm-isolated")
        #expect(second.tmuxResolver.sessionNames[tab.rootPaneId] == nil)
        #expect(first.getTerminal(for: tab.rootPaneId) === terminal)
        #expect(second.getTerminal(for: tab.rootPaneId) == nil)
        #expect(first.connectedServerIds == [tab.serverId])
        #expect(second.connectedServerIds.isEmpty)

        await first.unregisterSSHClient(for: tab.rootPaneId)
    }

    @Test
    func separateStoresRestoreOnlyTheirOwnSelectedState() {
        let firstStore = InMemoryTerminalTabSnapshotStore()
        let secondStore = InMemoryTerminalTabSnapshotStore()
        let first = makeManager(snapshotStore: firstStore)
        let second = makeManager(snapshotStore: secondStore)
        let serverId = UUID()
        let firstTab = TerminalTab(serverId: serverId, title: "First")
        let secondTab = TerminalTab(serverId: serverId, title: "Second")

        install(firstTab, in: first)
        first.selectView(.files, for: serverId)
        first.tmuxResolver.sessionNames[firstTab.rootPaneId] = "first-session"
        first.tmuxResolver.sessionOwnership[firstTab.rootPaneId] = .managed

        install(secondTab, in: second)
        second.selectView(.stats, for: serverId)

        first.persistAndRestoreSnapshotForTesting()
        second.persistAndRestoreSnapshotForTesting()

        let restoredFirst = makeManager(snapshotStore: firstStore)
        let restoredSecond = makeManager(snapshotStore: secondStore)

        #expect(restoredFirst.selectedTabId(for: serverId) == firstTab.id)
        #expect(restoredFirst.selectedView(for: serverId) == .files)
        #expect(restoredFirst.paneState(for: firstTab.rootPaneId) != nil)
        #expect(restoredFirst.paneState(for: secondTab.rootPaneId) == nil)
        #expect(restoredFirst.tmuxResolver.sessionNames[firstTab.rootPaneId] == "first-session")

        #expect(restoredSecond.selectedTabId(for: serverId) == secondTab.id)
        #expect(restoredSecond.selectedView(for: serverId) == .stats)
        #expect(restoredSecond.paneState(for: secondTab.rootPaneId) != nil)
        #expect(restoredSecond.paneState(for: firstTab.rootPaneId) == nil)
        #expect(restoredSecond.tmuxResolver.sessionNames[firstTab.rootPaneId] == nil)
    }

    private func makeManager(
        snapshotStore: InMemoryTerminalTabSnapshotStore
    ) -> TerminalTabManager {
        TerminalTabManager(
            snapshotStore: snapshotStore,
            networkReadinessPublisher: nil,
            liveActivityRefresh: { _ in },
            eternalTerminalResumeStore: IsolatedEternalTerminalResumeStore(),
            moshResumeStore: IsolatedMoshResumeStore()
        )
    }

    private func install(_ tab: TerminalTab, in manager: TerminalTabManager) {
        manager.installTabForTesting(tab, paneState: TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        ))
        manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
    }
}
