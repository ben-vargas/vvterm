import CoreGraphics
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttySurfaceRegistryTests {
    @Test
    func terminalCleanupRemovesSurfaceFromRegistry() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal: GhosttyTerminalView
        #if os(iOS)
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "surface-registry",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "surface-registry-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        #else
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "surface-registry",
            useCustomIO: true
        )
        #endif
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let surface = try #require(terminal.surface?.unsafeCValue)
        #expect(app.activeSurfaceCount() == 1)
        #expect(app.terminalView(for: surface) === terminal)

        terminal.cleanup()

        #expect(app.activeSurfaceCount() == 0)
        #expect(app.terminalView(for: surface) == nil)
    }

    @Test
    func surfaceReferenceWithoutTerminalViewIsPrunedFromRegistry() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        var terminal: GhosttyTerminalView?
        #if os(iOS)
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            paneId: "released-surface-registry",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "released-surface-registry-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        #else
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            paneId: "released-surface-registry",
            useCustomIO: true
        )
        #endif
        let registryToken = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            terminal?.cleanup()
            app.cleanup()
            registryToken.deallocate()
        }

        let registeredTerminal = try #require(terminal)
        registeredTerminal.cleanup()
        let surfaceReference = app.registerSurface(
            registryToken,
            terminalView: registeredTerminal
        )

        #expect(app.activeSurfaceCount() == 1)
        #expect(app.terminalView(for: registryToken) === registeredTerminal)

        surfaceReference.terminalView = nil

        #expect(app.activeSurfaceCount() == 0)
        #expect(app.terminalView(for: registryToken) == nil)
    }
}
