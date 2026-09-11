#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalViewportTests {
    @Test
    func modalInputReleaseRejectsNativeFocusAndAllowsSettingsTextField() throws {
        try withTerminal { terminal in
            #expect(!terminal.becomeFirstResponder())
            terminal.setTerminalInputAcquisitionAllowed(true)
            #expect(terminal.becomeFirstResponder())
            terminal.setTerminalInputAcquisitionAllowed(false)
            terminal.releaseTerminalInput()
            #expect(!terminal.becomeFirstResponder())
            #expect(!terminal.imeProxyTextView.canBecomeFirstResponder)
            #expect(!terminal.requestKeyboardFocus(for: .initialActivation))
            #expect(!terminal.canRouteTerminalInput)
            #expect(terminal.resolvedInputAccessoryView() == nil)

            let settingsField = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
            terminal.superview?.addSubview(settingsField)
            #expect(settingsField.becomeFirstResponder())
            #expect(!terminal.imeProxyTextView.isFirstResponder)
            settingsField.resignFirstResponder()
            settingsField.removeFromSuperview()

            terminal.setTerminalInputAcquisitionAllowed(true)
            #expect(terminal.becomeFirstResponder())
        }
    }

    @Test
    func pixelResizeWithinSameGridDoesNotReportRemoteResize() throws {
        try withTerminal { terminal in
            terminal.sizeDidChange(terminal.bounds.size)
            let initialGrid = terminal.lastReportedGrid
            let initialPixels = terminal.lastPixelSize
            var remoteResizeCount = 0
            terminal.onResize = { _, _ in remoteResizeCount += 1 }
            terminal.sizeDidChange(CGSize(width: terminal.bounds.width + 1, height: terminal.bounds.height))
            #expect(terminal.lastPixelSize != initialPixels)
            #expect(terminal.lastReportedGrid == initialGrid)
            #expect(remoteResizeCount == 0)
            terminal.sizeDidChange(CGSize(width: terminal.bounds.width, height: terminal.bounds.height - 100))
            #expect(terminal.lastReportedGrid.rows < initialGrid.rows)
            #expect(remoteResizeCount == 1)
        }
    }

    private func withTerminal(_ action: (GhosttyTerminalView) throws -> Void) throws {
        let runtime = GhosttyRuntime()
        defer { runtime.cleanup() }
        let handle = try #require(runtime.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: handle,
            appWrapper: runtime,
            paneId: "viewport-test",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "viewport-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        defer { terminal.cleanup() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = terminal.frame
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        window.rootViewController?.view.addSubview(terminal)
        try action(terminal)
    }
}
#endif
