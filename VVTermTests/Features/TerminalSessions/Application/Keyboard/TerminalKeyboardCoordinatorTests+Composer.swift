#if os(iOS)
import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

extension TerminalKeyboardCoordinatorTests {
    @Suite(.serialized)
    struct Composer {
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
#endif
