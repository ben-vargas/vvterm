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

        let surfaceWrapper = try #require(terminal.surface)
        let surface = try #require(surfaceWrapper.unsafeCValue)
        let callbackContext = surfaceWrapper.callbackContext
        let surfaceUserdata = try #require(ghostty_surface_userdata(surface))
        #expect(app.activeSurfaceCount() == 1)
        #expect(app.terminalView(for: surface) === terminal)
        #expect(surfaceUserdata == callbackContext.userdata)
        #expect(Ghostty.CallbackContext<GhosttyTerminalView>.resolve(surfaceUserdata) === terminal)

        terminal.cleanup()

        #expect(app.activeSurfaceCount() == 0)
        #expect(app.terminalView(for: surface) == nil)
        #expect(callbackContext.resolve() == nil)
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
