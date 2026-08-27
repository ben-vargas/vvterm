import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyRuntimeStateTests {
    @Test
    func deferredRuntimeStartsIdle() {
        let runtime = GhosttyRuntime(autoStart: false)
        defer { runtime.cleanup() }

        #expect(runtime.app == nil)
        #expect(runtime.readiness == .idle)
    }

    @Test
    func startedRuntimeIsReadyAndSecondStartIsIdempotent() throws {
        let runtime = GhosttyRuntime()
        defer { runtime.cleanup() }
        let initialApp = try #require(runtime.app)

        #expect(runtime.readiness == .ready)

        runtime.startIfNeeded()

        #expect(runtime.app == initialApp)
        #expect(runtime.readiness == .ready)
    }

    @Test
    func cleanupStopsRuntimeWithoutAllowingRestart() throws {
        let runtime = GhosttyRuntime()
        _ = try #require(runtime.app)

        runtime.cleanup()

        #expect(runtime.app == nil)
        #expect(runtime.readiness == .stopped)

        runtime.startIfNeeded()

        #expect(runtime.app == nil)
        #expect(runtime.readiness == .stopped)
    }

    @Test
    func cjkCodepointMapLoadsWithoutDiagnostics() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = directoryURL.appendingPathComponent("config")
        let content = [
            Ghostty.ConfigBuilder.fontFamilyLines(["Menlo"]),
            Ghostty.ConfigBuilder.fontCodepointMapLine(cjkFamily: "Menlo")
        ].joined(separator: "\n")
        try content.write(to: configURL, atomically: true, encoding: .utf8)

        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        GhosttyRuntime.loadConfigFile(config, atPath: configURL.path)
        ghostty_config_finalize(config)

        #expect(ghostty_config_diagnostics_count(config) == 0)
    }

    @Test
    func appOwnedConfigFileLoadsDirectlyWithAbsoluteThemePath() throws {
        let runtime = GhosttyRuntime()
        defer { runtime.cleanup() }
        _ = try #require(runtime.app)

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let themeURL = directoryURL.appendingPathComponent("Runtime Test Theme")
        try "background = 112233\nforeground = DDEEFF\n"
            .write(to: themeURL, atomically: true, encoding: .utf8)

        let configURL = directoryURL.appendingPathComponent("config")
        let content = Ghostty.ConfigBuilder.configContent(
            fontSelection: TerminalFontRuntimeSelection(
                primaryFamily: "Menlo",
                cjkFamily: nil
            ),
            fontSize: 19,
            contentPadding: TerminalContentPadding(horizontal: 7, vertical: 11),
            shellName: "zsh",
            theme: themeURL.path
        )
        try content.write(to: configURL, atomically: true, encoding: .utf8)

        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        GhosttyRuntime.loadConfigFile(config, atPath: configURL.path)
        ghostty_config_finalize(config)

        var fontSize: Float = 0
        let fontSizeKey = "font-size"
        let loadedFontSize = fontSizeKey.withCString { keyPointer in
            ghostty_config_get(config, &fontSize, keyPointer, UInt(fontSizeKey.utf8.count))
        }

        var background = ghostty_config_color_s()
        let backgroundKey = "background"
        let loadedBackground = backgroundKey.withCString { keyPointer in
            ghostty_config_get(config, &background, keyPointer, UInt(backgroundKey.utf8.count))
        }

        #expect(loadedFontSize)
        #expect(fontSize == 19)
        #expect(loadedBackground)
        #expect(background.r == 0x11)
        #expect(background.g == 0x22)
        #expect(background.b == 0x33)
    }
}
