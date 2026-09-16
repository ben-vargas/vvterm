#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalAccessoryRoutingTests {
    @Test
    func chatAccessoryRoutesExplicitInputAndBlocksInactivePane() async throws {
        let runtime = GhosttyRuntime()
        defer { runtime.cleanup() }
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: try #require(runtime.app), appWrapper: runtime,
            paneId: "chat-accessory",
            terminalAccessoryInputSnapshot: .init(profile: .defaultValue(lastWriterDeviceId: "test"),
                                                   showsDismissKeyboardButton: true),
            useCustomIO: true
        )
        defer { terminal.cleanup() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        window.rootViewController?.view.addSubview(terminal)
        terminal.acceptsTerminalInput = true
        terminal.setTerminalInputAcquisitionAllowed(false)
        var bytes = Data()
        terminal.writeCallback = { bytes.append($0) }
        terminal.setupWriteCallback()
        terminal.sendToolbarKey(.enter) // A stale text-input callback must remain blocked.
        terminal.sendText("blocked")
        terminal.sendToolbarKey(.tab, origin: .accessory)
        terminal.handleToolbarCustomAction(.init(title: "Command", kind: .command,
                                                 commandContent: "hello", commandSendMode: .insertAndEnter))
        terminal.handleToolbarCustomAction(.init(title: "Shortcut", kind: .shortcut,
                                                 shortcutKey: .a, shortcutModifiers: .none))
        try await Task.sleep(for: .milliseconds(100))
        #expect(String(decoding: bytes, as: UTF8.self) == "\thello\ra")
        terminal.acceptsTerminalInput = false
        terminal.sendToolbarKey(.enter, origin: .accessory)
        terminal.handleToolbarCustomAction(.init(title: "Blocked", kind: .command, commandContent: "blocked"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(String(decoding: bytes, as: UTF8.self) == "\thello\ra")
    }
}
#endif
