#if os(iOS)
import Combine
import Testing
import UIKit
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct TerminalKeyboardNativeDismissalTests {
    @Test
    func repeatedNativeFramesDoNotRepublishToolbarState() async {
        let source = TerminalKeyboardCoordinatorEventSourceSpy()
        let coordinator = TerminalKeyboardCoordinator(
            keyboardEventSource: source, lifecycleLoggingEnabled: false
        )
        let session = TerminalKeyboardInputSessionSpy()
        session.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 1024, height: 1000)
        coordinator.terminalProvider = { _ in session }
        coordinator.setActivePane(Self.paneId)
        coordinator.setPaneInputEligible(true, for: Self.paneId)
        coordinator.setWindowAttached(true, for: Self.paneId)
        coordinator.setViewActive(true)
        await drainMainQueue()
        source.send(.frameChanged(Self.dockedFrame), animationDuration: 0.25, animationCurve: .easeOut)
        await drainMainQueue()

        var publications = 0
        let observation = coordinator.objectWillChange.sink { publications += 1 }
        for _ in 0..<20 {
            source.send(.frameChanged(Self.dockedFrame), animationDuration: 0.25, animationCurve: .easeOut)
        }
        await drainMainQueue()
        #expect(publications == 0)
        withExtendedLifetime(observation) {}
    }

    @Test
    func layoutGuideFallbackDoesNotCountAsUserDismissal() async {
        let (coordinator, session) = await makeVisibleSession()
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
        session.snapshot.keyboardLayoutFrame = Self.dockedFrame
        coordinator.activeTerminalWindowDidBecomeKey(for: Self.paneId)
        await drainMainQueue()
        #expect(coordinator.isSoftwareKeyboardVisible)

        // A retained native guide can report the previous keyboard while the
        // new input session has only an accessory, with no visible event.
        coordinator.keyboardUITestReceiveKeyboardEndFrame(
            CGRect(x: 0, y: 952, width: 1024, height: 48), isLocal: true
        )
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await drainMainQueue()
        #expect(!coordinator.isUserHidden)
        #expect(!session.snapshot.isKeyboardInBrowseMode)
    }

    @Test
    func resizedLayoutGuideDoesNotReplaceObservedKeyboardFrame() async {
        let (coordinator, session) = await makeVisibleSession()
        session.snapshot.keyboardLayoutFrame = CGRect(x: 0, y: 650, width: 1024, height: 350)
        coordinator.activeTerminalWindowDidBecomeKey(for: Self.paneId)
        await drainMainQueue()
        #expect(coordinator.softwareKeyboardEndFrame == Self.dockedFrame)
    }

    @Test
    func switchingPaneDoesNotTransferNativeDismissalHistory() async {
        let (coordinator, session) = await makeVisibleSession()
        let nextPane = UUID()
        coordinator.terminalProvider = { _ in session }
        coordinator.setPaneInputEligible(true, for: nextPane)
        coordinator.setWindowAttached(true, for: nextPane)
        coordinator.setActivePane(nextPane)
        await drainMainQueue()
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(!coordinator.isUserHidden)
    }

    @Test(arguments: [false, true])
    func settledLocalHideUsesUserDismissal(floating: Bool) async {
        let (coordinator, session) = await makeVisibleSession(floating: floating)
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        // UIKit can send both will-hide and did-hide for the same transition.
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        #expect(!coordinator.isUserHidden)
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await drainMainQueue()
        #expect(coordinator.isUserHidden)
        #expect(session.snapshot.isKeyboardInBrowseMode)
        #expect(session.snapshot.isSoftwareKeyboardSuppressed)
        #expect(session.forceSoftwareKeyboardCount == 0)
        coordinator.userRequestedShow()
        await drainMainQueue()
        #expect(!coordinator.isUserHidden)
    }

    @Test
    func returningFrameCancelsDismissal() async {
        let (coordinator, _) = await makeVisibleSession()
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(Self.dockedFrame)
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(!coordinator.isUserHidden)
        #expect(coordinator.isSoftwareKeyboardVisible)
    }

    @Test
    func openingSettingsCancelsDismissal() async {
        let (coordinator, _) = await makeVisibleSession()
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        coordinator.deactivateInputImmediately(reason: .routeModal)
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(!coordinator.isUserHidden)
    }

    @Test(arguments: [false, true])
    func hardwareAttachmentDoesNotBecomeUserDismissal(attachesDuringHide: Bool) async {
        let (coordinator, session) = await makeVisibleSession()
        session.snapshot.hasHardwareKeyboardAttached = !attachesDuringHide
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        session.snapshot.hasHardwareKeyboardAttached = true
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(!coordinator.isUserHidden)
    }

    @Test
    func nativeDismissalStillWorksWithPreviouslyAttachedHardwareKeyboard() async {
        let (coordinator, _) = await makeVisibleSession(hardwareAttached: true)
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await drainMainQueue()
        #expect(coordinator.isUserHidden)
    }

    @Test
    func leavingActiveSceneCancelsDismissal() async {
        let (coordinator, _) = await makeVisibleSession()
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        coordinator.activeTerminalSceneWillDeactivate(for: Self.paneId)
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(!coordinator.isUserHidden)
    }

    @Test
    func hiddenFrameBeforeHideNotificationsPreservesDismissal() async {
        let (coordinator, _) = await makeVisibleSession()
        coordinator.keyboardUITestReceiveKeyboardEndFrame(
            CGRect(x: 0, y: 1000, width: 1024, height: 300), isLocal: true
        )
        coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await drainMainQueue()
        #expect(coordinator.isUserHidden)
    }

    private static let paneId = UUID()
    private static let dockedFrame = CGRect(x: 0, y: 700, width: 1024, height: 300)

    private func makeVisibleSession(floating: Bool = false, hardwareAttached: Bool = false) async
        -> (TerminalKeyboardCoordinator, TerminalKeyboardInputSessionSpy) {
        let paneId = Self.paneId
        let session = TerminalKeyboardInputSessionSpy()
        session.snapshot.hasHardwareKeyboardAttached = hardwareAttached
        session.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 1024, height: 1000)
        let coordinator = makeTerminalKeyboardCoordinator()
        coordinator.terminalProvider = { $0 == paneId ? session : nil }
        coordinator.setActivePane(paneId)
        coordinator.setViewActive(true)
        coordinator.setPaneInputEligible(true, for: paneId)
        coordinator.setWindowAttached(true, for: paneId)
        await drainMainQueue()
        coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            floating ? CGRect(x: 500, y: 500, width: 300, height: 250) : Self.dockedFrame
        )
        session.resetCommands()
        return (coordinator, session)
    }
}
#endif
