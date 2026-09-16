#if os(iOS)
import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

extension TerminalKeyboardCoordinatorTests {
    @Suite(.serialized)
    struct Composer {
        @Test @MainActor
        func tabTransferAcquiresIncomingEditorBeforeReleasingOutgoingEditor() async {
            let first = UUID(), second = UUID()
            let terminal = TerminalKeyboardInputSessionSpy()
            let outgoing = ComposerInputSpy(), incoming = ComposerInputSpy()
            let coordinator = makeTerminalKeyboardCoordinator()
            coordinator.terminalProvider = { _ in terminal }
            coordinator.inputModeProvider = { _ in .chat }
            for pane in [first, second] {
                coordinator.setPaneInputEligible(true, for: pane)
                coordinator.setWindowAttached(true, for: pane)
            }
            coordinator.setActivePane(first)
            coordinator.setViewActive(true)
            coordinator.registerComposerInput(outgoing, for: first)
            coordinator.registerComposerInput(incoming, for: second)
            await drainMainQueue()
            var events: [String] = []
            outgoing.onSetInput = { active in if !active { events.append("release") } }
            incoming.onSetInput = { active in if active { events.append("acquire") } }
            coordinator.setActivePane(second)
            await drainMainQueue()
            #expect(events.prefix(2).elementsEqual(["acquire", "release"]))
        }

        @Test @MainActor
        func nativeDismissalKeepsChatHiddenUntilExplicitShow() async {
            let pane = UUID()
            let terminal = TerminalKeyboardInputSessionSpy()
            let composer = ComposerInputSpy()
            let coordinator = makeTerminalKeyboardCoordinator()
            coordinator.terminalProvider = { _ in terminal }
            coordinator.inputModeProvider = { _ in .chat }
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            coordinator.setWindowAttached(true, for: pane)
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.registerComposerInput(composer, for: pane)
            await drainMainQueue()
            terminal.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 1024, height: 1000)
            terminal.snapshot.isSoftwareInputActive = false
            terminal.snapshot.isSoftwareKeyboardSuppressed = true
            coordinator.keyboardUITestReceiveKeyboardEndFrame(CGRect(x: 0, y: 700, width: 1024, height: 300), isLocal: true)
            #expect(coordinator.isSoftwareKeyboardVisible)
            composer.active = false // UIKit may resign before it sends the hidden frame.
            coordinator.keyboardUITestReceiveKeyboardEndFrame(CGRect(x: 0, y: 1000, width: 1024, height: 300), isLocal: true)
            coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
            await drainMainQueue()
            #expect(!composer.active) // A geometry update must not reopen the keyboard.
            try? await Task.sleep(for: .milliseconds(1100))
            await drainMainQueue()
            #expect(coordinator.isUserHidden)
            #expect(composer.keyboardHidden)
            coordinator.composerInputAvailabilityDidChange()
            await drainMainQueue()
            #expect(composer.keyboardHidden)
            coordinator.userRequestedShow()
            await drainMainQueue()
            #expect(!composer.keyboardHidden)
        }

        enum NativeHideInterruption: CaseIterable {
            case picker, scene, hardwareKeyboard, returningFrame, explicitShow, replacement, modeChange
        }

        @Test(arguments: NativeHideInterruption.allCases) @MainActor
        func interruptedChatHideDoesNotBecomeUserDismissal(_ interruption: NativeHideInterruption) async {
            let pane = UUID()
            let terminal = TerminalKeyboardInputSessionSpy()
            let composer = ComposerInputSpy()
            let replacement = ComposerInputSpy()
            let coordinator = makeTerminalKeyboardCoordinator()
            var mode = TerminalInputMode.chat
            coordinator.terminalProvider = { _ in terminal }
            coordinator.inputModeProvider = { _ in mode }
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            coordinator.setWindowAttached(true, for: pane)
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.registerComposerInput(composer, for: pane)
            await drainMainQueue()
            terminal.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 1024, height: 1000)
            let frame = CGRect(x: 0, y: 700, width: 1024, height: 300)
            coordinator.keyboardUITestReceiveKeyboardEndFrame(frame, isLocal: true)
            coordinator.keyboardUITestReceiveSoftwareKeyboardHidden()
            switch interruption {
            case .picker:
                composer.allowsComposerFocus = false
                coordinator.composerInputAvailabilityDidChange()
            case .scene:
                coordinator.activeTerminalSceneWillDeactivate(for: pane)
            case .hardwareKeyboard:
                terminal.snapshot.hasHardwareKeyboardAttached = true
            case .returningFrame:
                coordinator.keyboardUITestReceiveKeyboardEndFrame(frame, isLocal: true)
            case .explicitShow:
                coordinator.userRequestedShow()
            case .replacement:
                coordinator.registerComposerInput(replacement, for: pane)
            case .modeChange:
                mode = .direct
                coordinator.composerModeDidChange(for: pane)
            }
            try? await Task.sleep(for: .milliseconds(1100))
            await drainMainQueue()
            #expect(!coordinator.isUserHidden)
            if interruption == .replacement { #expect(replacement.active) }
        }

        @Test @MainActor
        func systemOverlayPreservesChatKeyboardPresentation() async {
            let pane = UUID()
            let terminal = TerminalKeyboardInputSessionSpy()
            let composer = ComposerInputSpy()
            let coordinator = makeTerminalKeyboardCoordinator()
            coordinator.terminalProvider = { _ in terminal }
            coordinator.inputModeProvider = { _ in .chat }
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            coordinator.setWindowAttached(true, for: pane)
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.registerComposerInput(composer, for: pane)
            await drainMainQueue()
            let frame = CGRect(x: 0, y: 700, width: 400, height: 300)
            terminal.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 400, height: 1000)
            coordinator.keyboardUITestReceiveKeyboardEndFrame(frame, isLocal: true)
            coordinator.activeTerminalSceneWillDeactivate(for: pane)
            await drainMainQueue()
            #expect(coordinator.softwareKeyboardEndFrame == frame)
            #expect(coordinator.isComposerVisible(for: pane))
            #expect(composer.active)
            terminal.snapshot.windowIsKey = false
            coordinator.activeTerminalSceneDidActivate(for: pane)
            await drainMainQueue()
            #expect(!coordinator.activeTerminalSceneIsForeground)
            #expect(composer.active)
            #expect(coordinator.softwareKeyboardEndFrame == frame)
            terminal.snapshot.windowIsKey = true
            coordinator.activeTerminalWindowDidBecomeKey(for: pane)
            coordinator.activeTerminalSceneDidActivate(for: pane)
            await drainMainQueue()
            #expect(coordinator.activeTerminalSceneIsForeground)
            #expect(coordinator.softwareKeyboardEndFrame == frame)
            #expect(composer.active)
            #expect(terminal.rebuildCount == 0)
        }

        @Test @MainActor
        func terminalTapDismissesChatUntilExplicitFocusReturns() async {
            let pane = UUID()
            let terminal = TerminalKeyboardInputSessionSpy()
            let composer = ComposerInputSpy()
            let coordinator = makeTerminalKeyboardCoordinator()
            coordinator.terminalProvider = { _ in terminal }
            coordinator.inputModeProvider = { _ in .chat }
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            coordinator.setWindowAttached(true, for: pane)
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.registerComposerInput(composer, for: pane)
            await drainMainQueue()

            coordinator.directTouchOnTerminal(isFocusTap: true)
            await drainMainQueue()
            #expect(coordinator.isUserHidden)
            #expect(composer.keyboardHidden)
            #expect(coordinator.isComposerVisible(for: pane))
            #expect(coordinator.canSubmitComposedInput(for: pane))

            coordinator.composerInputAvailabilityDidChange()
            coordinator.activeTerminalSceneWillDeactivate(for: pane)
            coordinator.activeTerminalSceneDidActivate(for: pane)
            coordinator.directTouchOnTerminal(isFocusTap: true)
            await drainMainQueue()
            #expect(coordinator.isUserHidden)
            #expect(composer.keyboardHidden)

            coordinator.userRequestedShow()
            await drainMainQueue()
            #expect(!coordinator.isUserHidden)
            #expect(composer.active && !composer.keyboardHidden)

            // An active editor with a hardware keyboard still needs a Show command.
            coordinator.userRequestedKeyboardCommand()
            #expect(!coordinator.isUserHidden)
            terminal.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 400, height: 1000)
            coordinator.keyboardUITestReceiveKeyboardEndFrame(CGRect(x: 0, y: 700, width: 400, height: 300), isLocal: true)
            coordinator.userRequestedKeyboardCommand()
            await drainMainQueue()
            #expect(coordinator.isUserHidden)
            coordinator.userRequestedKeyboardCommand()
            await drainMainQueue()
            #expect(!coordinator.isUserHidden)
            coordinator.setFindNavigatorActive(true, for: pane)
            await drainMainQueue()
            coordinator.userRequestedKeyboardCommand()
            #expect(!coordinator.isUserHidden)
        }

        @Test @MainActor
        func modeTransfersInputAndSurvivesPaneReconnectFindAndSceneChanges() async {
            let pane = UUID(), other = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            let second = TerminalKeyboardInputSessionSpy()
            session.snapshot.isSoftwareInputActive = false
            second.snapshot.isSoftwareInputActive = false
            let coordinator = makeTerminalKeyboardCoordinator()
            var mode = TerminalInputMode.direct
            coordinator.inputModeProvider = { $0 == pane ? mode : .direct }
            coordinator.terminalProvider = { $0 == pane ? session : second }
            for id in [pane, other] {
                coordinator.setPaneInputEligible(true, for: id)
                coordinator.setWindowAttached(true, for: id)
            }
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            await drainMainQueue()
            #expect(session.acquireCount > 0)
            session.resetCommands()

            mode = .chat
            coordinator.composerModeDidChange(for: pane)
            #expect(session.releaseCount > 0)
            await drainMainQueue()
            #expect(session.acquireCount == 0)
            #expect(coordinator.canSubmitComposedInput(for: pane))

            coordinator.setPaneInputEligible(false, for: pane)
            await drainMainQueue()
            #expect(!coordinator.canSubmitComposedInput(for: pane))
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.setFindNavigatorActive(true, for: pane)
            await drainMainQueue()
            #expect(!coordinator.canSubmitComposedInput(for: pane))
            coordinator.setFindNavigatorActive(false, for: pane)
            coordinator.setViewActive(false)
            await drainMainQueue()
            #expect(!coordinator.canSubmitComposedInput(for: pane))
            coordinator.setViewActive(true)
            await drainMainQueue()
            #expect(session.acquireCount == 0)

            coordinator.setActivePane(other)
            await drainMainQueue()
            #expect(second.acquireCount > 0)
            #expect(!coordinator.canSubmitComposedInput(for: pane))
            coordinator.setActivePane(pane)
            await drainMainQueue()
            #expect(session.acquireCount == 0)

            mode = .direct
            coordinator.composerModeDidChange(for: pane)
            await drainMainQueue()
            #expect(session.acquireCount > 0)
        }

        @Test @MainActor
        func coordinatorOwnsComposerFocusAcrossFindDisconnectCloseAndExternalInput() async {
            let pane = UUID(), other = UUID()
            let terminal = TerminalKeyboardInputSessionSpy()
            let composer = ComposerInputSpy()
            let coordinator = makeTerminalKeyboardCoordinator()
            coordinator.terminalProvider = { _ in terminal }
            coordinator.inputModeProvider = { _ in .chat }
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            coordinator.setWindowAttached(true, for: pane)
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.registerComposerInput(composer, for: pane)
            await drainMainQueue()
            #expect(composer.active)
            #expect(coordinator.isComposerVisible(for: pane))
            coordinator.setFindNavigatorActive(true, for: pane)
            await drainMainQueue()
            #expect(!composer.active)
            #expect(!coordinator.isComposerVisible(for: pane))
            coordinator.setFindNavigatorActive(false, for: pane)
            await drainMainQueue()
            #expect(composer.active)
            coordinator.setPaneInputEligible(false, for: pane)
            await drainMainQueue()
            #expect(!composer.active)
            coordinator.setPaneInputEligible(true, for: pane)
            await drainMainQueue()
            #expect(composer.active)
            coordinator.userRequestedHide()
            await drainMainQueue()
            #expect(composer.active && composer.keyboardHidden)
            coordinator.userRequestedShow()
            await drainMainQueue()
            #expect(composer.active && !composer.keyboardHidden)
            coordinator.activeTerminalSceneWillDeactivate(for: pane)
            await drainMainQueue()
            #expect(composer.active)
            coordinator.activeTerminalSceneDidActivate(for: pane)
            await drainMainQueue()
            #expect(composer.active)
            coordinator.keyboardUITestReceiveKeyboardEndFrame(nil, isLocal: false)
            await drainMainQueue()
            #expect(!composer.active)
            coordinator.userRequestedShow()
            await drainMainQueue()
            #expect(composer.active)
            coordinator.setActivePane(other)
            await drainMainQueue()
            #expect(!composer.active)
            coordinator.setActivePane(pane)
            await drainMainQueue()
            #expect(composer.active)
            coordinator.deactivateInputImmediately(reason: .routeModal)
            #expect(!composer.active)
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            await drainMainQueue()
            #expect(composer.active)
            coordinator.relinquishRouteOwnershipForNavigation()
            #expect(!composer.allowsAcquisition)
            #expect(composer.active) // UIKit releases it when navigation removes the view.
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            await drainMainQueue()
            coordinator.removePane(pane)
            #expect(!composer.active)
        }

        @Test @MainActor
        func replacingComposerRejectsOldViewTeardown() async {
            let pane = UUID()
            let terminal = TerminalKeyboardInputSessionSpy()
            let old = ComposerInputSpy(), replacement = ComposerInputSpy()
            let coordinator = makeTerminalKeyboardCoordinator()
            coordinator.terminalProvider = { _ in terminal }
            coordinator.inputModeProvider = { _ in .chat }
            coordinator.setActivePane(pane)
            coordinator.setViewActive(true)
            coordinator.setWindowAttached(true, for: pane)
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.registerComposerInput(old, for: pane)
            await drainMainQueue()
            #expect(old.active)
            coordinator.registerComposerInput(replacement, for: pane)
            coordinator.unregisterComposerInput(old, for: pane)
            await drainMainQueue()
            #expect(!old.active)
            #expect(replacement.active)
            coordinator.removePane(pane)
            #expect(!replacement.active)
        }

        @Test @MainActor
        func composerKeyboardGeometryDoesNotRequireGhosttyResponder() async {
            let pane = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 1024, height: 1000)
            session.snapshot.isSoftwareKeyboardSuppressed = true
            let events = TerminalKeyboardCoordinatorEventSourceSpy()
            let coordinator = TerminalKeyboardCoordinator(keyboardEventSource: events, lifecycleLoggingEnabled: false)
            coordinator.terminalProvider = { _ in session }
            coordinator.inputModeProvider = { _ in .chat }
            coordinator.setActivePane(pane)
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.setWindowAttached(true, for: pane)
            coordinator.setViewActive(true)
            coordinator.composerModeDidChange(for: pane)
            await drainMainQueue()
            let composer = ComposerInputSpy()
            coordinator.registerComposerInput(composer, for: pane)
            await drainMainQueue()
            let docked = CGRect(x: 0, y: 700, width: 1024, height: 300)
            events.send(.frameChanged(docked))
            await drainMainQueue()
            #expect(coordinator.softwareKeyboardEndFrame == docked)
            #expect(!session.snapshot.isSoftwareInputActive)
            let floating = CGRect(x: 500, y: 400, width: 320, height: 260)
            events.send(.frameChanged(floating))
            await drainMainQueue()
            #expect(coordinator.softwareKeyboardEndFrame == floating)
            #expect(session.acquireCount == 0)
            events.send(.hidden)
            #expect(!coordinator.isSoftwareKeyboardVisible)
        }

        @Test @MainActor
        func explicitSendDoesNotRequireTerminalKeyboardOwnership() async {
            let pane = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            let coordinator = makeTerminalKeyboardCoordinator()
            coordinator.terminalProvider = { _ in session }
            coordinator.inputModeProvider = { _ in .chat }
            coordinator.setActivePane(pane)
            coordinator.setPaneInputEligible(true, for: pane)
            coordinator.setWindowAttached(true, for: pane)
            coordinator.setViewActive(true)
            await drainMainQueue()
            // A picker or another keyboard can report external ownership while
            // the connected, selected pane remains a valid explicit send target.
            coordinator.keyboardUITestReceiveKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 400, height: 300), isLocal: false
            )
            await drainMainQueue()
            #expect(coordinator.canSubmitComposedInput(for: pane))
            #expect(!coordinator.canSubmitComposedInput(for: UUID()))
            coordinator.activeTerminalSceneWillDeactivate(for: pane)
            #expect(!coordinator.canSubmitComposedInput(for: pane))
        }

        @Test
        func chatNeverAcquiresTerminalForEitherKeyboardPreference() {
            for hidden in [true, false] {
                let inputs = TerminalKeyboardCoordinator.StateInputs(
                    viewActive: true, activePaneInputEligible: true,
                    activePaneWindowAttached: true, allowsLocalInputOwnership: true,
                    userHidKeyboard: hidden, findNavigatorActive: false, inputMode: .chat
                )
                #expect(!TerminalKeyboardCoordinator.desiredInputSessionActive(inputs: inputs))
                #expect(!TerminalKeyboardCoordinator.desiredKeyboardVisible(inputs: inputs))
            }
        }
    }
}
@MainActor
private final class ComposerInputSpy: TerminalComposerInputSession {
    var onSetInput: ((Bool) -> Void)?
    var allowsComposerFocus = true
    var active = false
    var allowsAcquisition = false
    var keyboardHidden = false
    var isComposerFirstResponder: Bool { active }
    func preventComposerInputAcquisition() { allowsAcquisition = false }
    func setComposerInput(active: Bool, softwareKeyboardHidden: Bool) {
        onSetInput?(active)
        self.active = active
        allowsAcquisition = active
        keyboardHidden = softwareKeyboardHidden
    }
}
#endif
