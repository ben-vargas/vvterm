#if os(iOS)
import XCTest

final class TerminalSettingsNavigationUITests: TerminalReconnectUITestCase {
    @MainActor
    func testServerListCanOpenSettingsFromItsToolbar() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.root"]
                .waitForExistence(timeout: 8),
            "Settings did not open from the server list toolbar."
        )
    }

    @MainActor
    func testGroupedSettingsOpenGeneralAndTerminalPages() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let navigationRoute = app.buttons["vvterm.settings.route.navigationAndStats"]
        XCTAssertTrue(navigationRoute.waitForExistence(timeout: 8))
        navigationRoute.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.page.navigationAndStats"]
                .waitForExistence(timeout: 8),
            "The General-derived Navigation & Stats page did not open."
        )
        XCTAssertTrue(app.buttons["Stats Appearance"].exists)

        let settingsBackButton = app.navigationBars["Navigation & Stats"].buttons["Settings"]
        XCTAssertTrue(settingsBackButton.waitForExistence(timeout: 5))
        settingsBackButton.tap()

        let searchField = app.searchFields["Search Settings"]
        if !searchField.waitForExistence(timeout: 2) {
            app.swipeDown()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("tmux")

        let sessionsRoute = app.buttons["vvterm.settings.route.sessionsAndConnections"]
        XCTAssertTrue(sessionsRoute.waitForExistence(timeout: 5))
        sessionsRoute.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.page.sessionsAndConnections"]
                .waitForExistence(timeout: 8),
            "The Terminal-derived Sessions & Connections page did not open."
        )
        XCTAssertTrue(app.switches["Enable tmux by default"].exists)
    }

    @MainActor
    func testConnectedTerminalCanOpenSettingsFromItsToolbar() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-reconnect-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-sshAutoReconnect", "YES",
            "-terminalTmuxEnabledDefault", "NO",
            "-terminalUsePerAppearanceTheme", "NO",
            "-terminalThemeName", "Aizen Dark",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(
            for: diagnostics,
            containing: "setup=ready state=connected",
            timeout: 45,
            app: app
        )

        openProductionTerminalMenu(in: app)
        let settings = app.buttons["vvterm.terminal.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), diagnosticText(in: app))
        settings.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.root"]
                .waitForExistence(timeout: 8),
            "Settings did not open from the connected terminal toolbar. \(diagnosticText(in: app))"
        )
    }

}
#endif
