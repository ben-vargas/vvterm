#if os(iOS)
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalInteractionOwnershipTests {
    @Test
    func terminalInteractionsAreInstalledAndReleased() async throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "interaction-ownership",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "interaction-ownership-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        defer { terminal.cleanup() }

        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        presenter.view.addSubview(terminal)

        terminal.terminalContextMenuActions = TerminalContextMenuActions(
            focus: {},
            splitRight: {},
            splitLeft: {},
            splitDown: {},
            splitUp: {},
            currentTitle: { "" },
            setTitle: { _ in }
        )

        let nativeSelection = try #require(terminal.nativeTextInteraction)
        let pointerMenu = try #require(terminal.editMenuInteraction)
        let interactionTextInput = nativeSelection.textInput as AnyObject?

        terminal.layoutIfNeeded()
        #expect(nativeSelection.view === terminal.imeProxyTextView)
        #expect(nativeSelection.textInteractionMode == .editable)
        #expect(interactionTextInput === terminal.imeProxyTextView)
        #expect(interactionTextInput !== terminal)
        #expect(terminal.imeProxyTextView.textInputView === terminal.imeProxyTextView)
        #expect(terminal.imeProxyTextView.frame == terminal.bounds)
        #expect(terminal.imeProxyTextView.isMultipleTouchEnabled)
        #expect(terminal.pinchRecognizer.view === terminal)
        #expect(terminal.directTouchTapRecognizer.view === terminal.imeProxyTextView)
        #expect(terminal.nativeSelectionLongPressRecognizer.view === terminal)
        let proxyTapCounts = terminal.imeProxyTextView.gestureRecognizers?
            .compactMap { ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired }
            ?? []
        #expect(proxyTapCounts.contains(1))
        #expect(proxyTapCounts.contains(2))
        #expect(proxyTapCounts.contains(3))
        #expect(
            terminal.imeProxyTextView.point(
                inside: CGPoint(x: terminal.bounds.midX, y: terminal.bounds.midY),
                with: nil
            )
        )
        #expect(pointerMenu.view === terminal)
        #expect(
            !terminal.gestureRecognizer(
                terminal.pinchRecognizer,
                shouldRecognizeSimultaneouslyWith: terminal.scrollRecognizer
            )
        )

        terminal.keyboardUITestSetHardwareKeyboardAttached(false)

        terminal.nativeSelectionSnapshot = TerminalNativeTextSnapshot(
            lines: ["one two"],
            cellSize: CGSize(width: 10, height: 20),
            columns: 7
        )
        let textInput = terminal.imeProxyTextView
        #expect(terminal.terminalInputConfiguration == .systemWithAccessory)
        #expect(textInput.inputView == nil)
        #expect(!terminal.shouldHideKeyboardAccessoryBar)
        #expect(textInput.inputAccessoryView != nil)
        #expect(!terminal.keyboardCoordinatorDiagnosticSnapshot().isSoftwareKeyboardSuppressed)

        terminal.nativeSelectionLifecycle.prepare(restoreTerminalInput: true)
        terminal.nativeSelectionLifecycle.beginInteraction(restoreTerminalInput: true)
        _ = terminal.nativeSelectionLifecycle.setSelection(
            NSRange(location: 0, length: 3)
        )
        _ = terminal.nativeSelectionLifecycle.endInteraction()

        #expect(textInput.documentMode == .nativeSelection)
        #expect(textInput.text(in: try #require(textInput.selectedTextRange)) == "one")
        #expect(terminal.terminalInputConfiguration == .systemWithAccessory)
        #expect(textInput.inputView == nil)
        #expect(!terminal.shouldHideKeyboardAccessoryBar)
        #expect(textInput.inputAccessoryView != nil)
        #expect(!terminal.keyboardCoordinatorDiagnosticSnapshot().isSoftwareKeyboardSuppressed)
        let selectionMenuTitles = Set(
            terminal.nativeSelectionMenuElements().compactMap {
                ($0 as? UIAction)?.title
            }
        )
        #expect(selectionMenuTitles.contains(String(localized: "Copy")))
        #expect(selectionMenuTitles.contains(String(localized: "Paste")))
        #expect(selectionMenuTitles.contains(String(localized: "Select All")))
        #expect(selectionMenuTitles.contains(String(localized: "Find")))

        let minimumPosition = TerminalNativeTextPosition(offset: Int.min)
        let maximumPosition = TerminalNativeTextPosition(offset: Int.max)
        #expect(textInput.offset(from: minimumPosition, to: maximumPosition) == 7)
        let extremeRange = try #require(
            textInput.textRange(from: minimumPosition, to: maximumPosition)
                as? TerminalNativeTextRange
        )
        #expect(extremeRange.nsRange == NSRange(location: 0, length: Int.max))
        #expect(
            textInput.characterOffset(of: maximumPosition, within: extremeRange) == 7
        )

        terminal.clearNativeSelectionStateForTerminalInput()
        #expect(textInput.documentMode == .terminalInput)

        let titleEditor = UIAlertController(
            title: "Test",
            message: nil,
            preferredStyle: .alert
        )
        terminal.terminalTitleEditor = titleEditor
        presenter.present(titleEditor, animated: false)
        #expect(presenter.presentedViewController === titleEditor)

        terminal.cleanup()
        #expect(nativeSelection.view == nil)
        let titleEditorDismissed = await waitUntil {
            titleEditor.presentingViewController == nil
        }

        #expect(terminal.editMenuInteraction == nil)
        #expect(pointerMenu.view == nil)
        #expect(terminal.terminalTitleEditor == nil)
        #expect(titleEditorDismissed)
        #expect(terminal.terminalContextMenuActions == nil)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}
#endif
