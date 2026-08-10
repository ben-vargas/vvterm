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

        #expect(nativeSelection.view === terminal)
        #expect(pointerMenu.view === terminal)

        let titleEditor = UIAlertController(
            title: "Test",
            message: nil,
            preferredStyle: .alert
        )
        terminal.terminalTitleEditor = titleEditor
        presenter.present(titleEditor, animated: false)
        #expect(presenter.presentedViewController === titleEditor)

        terminal.cleanup()
        for _ in 0..<3 where titleEditor.presentingViewController != nil {
            await nextMainQueueTurn()
        }

        #expect(terminal.editMenuInteraction == nil)
        #expect(pointerMenu.view == nil)
        #expect(terminal.terminalTitleEditor == nil)
        #expect(titleEditor.presentingViewController == nil)
        #expect(terminal.terminalContextMenuActions == nil)
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
#endif
