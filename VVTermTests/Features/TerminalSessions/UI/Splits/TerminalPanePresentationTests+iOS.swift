#if os(iOS)
import UIKit
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct TerminalPanePresentationTests: TerminalTabManagerTestSupport {
    @Test
    func oldPresenterCannotPauseAReusedTerminal() async throws {
        let manager = TerminalTestComposition.makeManager()
        let server = makeServer()
        let tab = TerminalTab(serverId: server.id, title: "Notification source")
        installTab(tab, in: manager)
        let runtime = GhosttyRuntime(configuration: .defaultValue)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), worktreePath: NSTemporaryDirectory(),
            ghosttyApp: try #require(runtime.app), appWrapper: runtime, paneId: tab.rootPaneId.uuidString,
            terminalAccessoryInputSnapshot: .init(profile: .defaultValue(lastWriterDeviceId: "presentation-test"), showsDismissKeyboardButton: true),
            useCustomIO: true
        )
        defer { terminal.cleanup(); runtime.cleanup() }
        manager.registerTerminalSurface(terminal, for: tab.rootPaneId)
        let old = makePresenter(tab, server: server, manager: manager)
        let current = makePresenter(tab, server: server, manager: manager)
        old.terminal = terminal
        current.terminal = terminal
        terminal.panePresentationOwner = current
        terminal.acceptsTerminalInput = true
        terminal.resumeRendering()
        terminal.onOpenLink = { _ in }

        // SwiftUI can finish removing the old host after the retained UIView
        // has already been attached to a new host during navigation.
        RemoteTerminalPaneRepresentable.dismantleUIView(terminal, coordinator: old)
        #expect(!terminal.isRenderingPaused)
        #expect(terminal.acceptsTerminalInput)
        #expect(terminal.onOpenLink != nil)
        #expect(terminal.panePresentationOwner === current)

        // The actual owner must still pause input and drawing when it leaves.
        RemoteTerminalPaneRepresentable.dismantleUIView(terminal, coordinator: current)
        #expect(terminal.isRenderingPaused)
        #expect(!terminal.acceptsTerminalInput)
        #expect(terminal.onOpenLink == nil)
        #expect(terminal.panePresentationOwner == nil)
        await manager.resetForTesting()
    }

    private func makePresenter(_ tab: TerminalTab, server: Server, manager: TerminalTabManager) -> TerminalPaneConnectionCoordinator {
        TerminalPaneConnectionCoordinator(
            paneId: tab.rootPaneId, server: server, credentials: .init(serverId: server.id),
            tabManager: manager, sshFailureOutput: { _ in nil }
        )
    }
}
#endif
