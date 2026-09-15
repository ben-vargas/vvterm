#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct TerminalSelectionDisplayInteractionTests {
    @Test
    func laterUIKitUpdatesCannotShowOffscreenHandles() throws {
        guard #available(iOS 17.0, *) else { return }
        let runtime = GhosttyRuntime()
        defer { runtime.cleanup() }
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: try #require(runtime.app), appWrapper: runtime,
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "selection-display-test"),
                showsDismissKeyboardButton: true
            ), useCustomIO: true
        )
        defer { terminal.cleanup() }
        let display = try #require(terminal.imeProxyTextView.interactions.compactMap {
            $0 as? UITextSelectionDisplayInteraction
        }.first)
        for (startVisible, endVisible) in [(true, false), (false, true), (false, false), (true, true)] {
            terminal.nativeSelectionSnapshot = TerminalNativeTextSnapshot(
                lines: ["first", "last"], cellSize: .init(width: 10, height: 20), columns: 5,
                selectionStartIsVisible: startVisible, selectionEndIsVisible: endVisible
            )
            _ = terminal.nativeSelectionLifecycle.setProjection(.visible(NSRange(location: 0, length: 5)))
            display.isActivated = true
            display.layoutManagedSubviews()
            for (visible, handle) in zip([startVisible, endVisible], display.handleViews) {
                // A deferred UIKit pass can change visibility after our layout call.
                handle.isHidden = false
                #expect((handle.layer.mask == nil) == visible)
                if let mask = handle.layer.mask {
                    #expect(mask.contents == nil)
                    #expect(mask.backgroundColor == nil)
                    #expect(mask.sublayers == nil)
                }
                handle.isHidden = true
                #expect(handle.isHidden)
            }
        }
    }
}
#endif
