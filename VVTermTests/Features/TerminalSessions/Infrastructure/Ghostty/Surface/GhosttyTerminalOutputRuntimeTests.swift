import CoreGraphics
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalOutputRuntimeTests {
    @Test
    func largeTerminalResponseBurstCompletesWithoutBlockingMainActor() async throws {
        let app = GhosttyRuntime()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)
        let terminal = makeTerminal(app: app, appHandle: appHandle)
        defer { terminal.cleanup() }

        let output = String(repeating: "\u{1B}[c", count: 96)

        #expect(await terminal.receiveTerminalOutput(Data(output.utf8)))
    }

    @Test
    func cleanupReleasesIdleSurfaceBeforeRuntimeShutdown() throws {
        let app = GhosttyRuntime()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)
        let terminal = makeTerminal(app: app, appHandle: appHandle)
        let surface = try #require(terminal.surface)

        terminal.cleanup()

        #expect(surface.unsafeCValue == nil)
    }

    private func makeTerminal(
        app: GhosttyRuntime,
        appHandle: ghostty_app_t
    ) -> GhosttyTerminalView {
        #if os(iOS)
        GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "large-terminal-response-burst",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "large-terminal-response-burst-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        #else
        GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "large-terminal-response-burst",
            useCustomIO: true
        )
        #endif
    }
}
