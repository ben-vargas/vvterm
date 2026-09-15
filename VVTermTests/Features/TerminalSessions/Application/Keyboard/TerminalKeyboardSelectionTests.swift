#if os(iOS)
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct TerminalKeyboardSelectionTests {
    @Test(arguments: [false, true])
    func automaticFocusDoesNotInterruptSelection(softwareInputActive: Bool) async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.snapshot.hasNativeSelection = true
        session.snapshot.isSoftwareInputActive = softwareInputActive
        let coordinator = makeTerminalKeyboardCoordinator()
        coordinator.terminalProvider = { $0 == paneId ? session : nil }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        coordinator.activeTerminalSceneDidActivate(for: paneId)
        await drainMainQueue()
        try? await Task.sleep(for: .milliseconds(1200))
        await drainMainQueue()
        #expect(session.acquireCount == 0)
        #expect(session.rebuildCount == 0)
        #expect(session.releaseCount == 0)
        #expect(session.accessoryReloadCount == 0)
    }

    @Test
    func explicitKeyboardRequestCanEndSelection() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.snapshot.hasNativeSelection = true
        session.snapshot.isSoftwareInputActive = false
        let coordinator = makeTerminalKeyboardCoordinator()
        coordinator.terminalProvider = { $0 == paneId ? session : nil }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        coordinator.userRequestedShow()
        await drainMainQueue()
        #expect(session.forceSoftwareKeyboardCount == 1)
    }

    @Test
    func leavingTerminalStillReleasesSelectionResponder() async {
        let paneId = UUID()
        let session = TerminalKeyboardInputSessionSpy()
        session.snapshot.hasNativeSelection = true
        let coordinator = makeTerminalKeyboardCoordinator()
        coordinator.terminalProvider = { $0 == paneId ? session : nil }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        session.resetCommands()
        coordinator.setViewActive(false)
        await drainMainQueue()
        #expect(session.releaseCount == 1)
    }
}
#endif
