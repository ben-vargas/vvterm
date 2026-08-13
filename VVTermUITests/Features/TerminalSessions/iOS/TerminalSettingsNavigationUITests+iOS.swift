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
            "The Server Views page did not open."
        )
        XCTAssertTrue(app.buttons["Stats Appearance"].exists)

        let settingsBackButton = app.navigationBars["Server Views"].buttons["Settings"]
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
            "The Sessions & SSH page did not open."
        )
        XCTAssertTrue(app.switches["Enable tmux by default"].exists)
        XCTAssertTrue(app.switches["Keep screen awake"].exists)
    }

    @MainActor
    func testAppearanceAndCursorChoicesAreSelectedButtons() throws {
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

        let appearanceRoute = app.buttons["vvterm.settings.route.appearanceAndLanguage"]
        XCTAssertTrue(appearanceRoute.waitForExistence(timeout: 8))
        appearanceRoute.tap()

        let systemAppearance = app.buttons["vvterm.settings.appearance.system"]
        let lightAppearance = app.buttons["vvterm.settings.appearance.light"]
        let darkAppearance = app.buttons["vvterm.settings.appearance.dark"]
        XCTAssertTrue(systemAppearance.waitForExistence(timeout: 5))
        XCTAssertEqual([systemAppearance, lightAppearance, darkAppearance].filter(\.isSelected).count, 1)
        let appearanceTarget = darkAppearance.isSelected ? lightAppearance : darkAppearance
        appearanceTarget.tap()
        XCTAssertTrue(appearanceTarget.isSelected)

        app.navigationBars["Appearance & Language"].buttons["Settings"].tap()

        let terminalAppearanceRoute = app.buttons["vvterm.settings.route.terminalAppearance"]
        XCTAssertTrue(terminalAppearanceRoute.waitForExistence(timeout: 5))
        terminalAppearanceRoute.tap()

        let blockCursor = app.buttons["vvterm.settings.cursor.block"]
        let barCursor = app.buttons["vvterm.settings.cursor.bar"]
        XCTAssertTrue(blockCursor.waitForExistence(timeout: 5))
        let underlineCursor = app.buttons["vvterm.settings.cursor.underline"]
        XCTAssertEqual([blockCursor, barCursor, underlineCursor].filter(\.isSelected).count, 1)
        let cursorTarget = barCursor.isSelected ? blockCursor : barCursor
        cursorTarget.tap()
        XCTAssertTrue(cursorTarget.isSelected)
    }

    @MainActor
    func testRemoteClipboardShowsOneWarning() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-terminalRemoteClipboardReadPolicy", "allow",
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

        let clipboardRoute = app.buttons["vvterm.settings.route.clipboardAndPaste"]
        XCTAssertTrue(clipboardRoute.waitForExistence(timeout: 8))
        clipboardRoute.tap()

        XCTAssertTrue(
            app.staticTexts["Warning: Remote programs can read your clipboard without asking."]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.staticTexts["Remote programs can read clipboard data without asking."].exists
        )
    }

    @MainActor
    func testKeyboardInputUsesFocusedSections() throws {
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

        let keyboardRoute = app.buttons["vvterm.settings.route.keyboardAndInput"]
        if !keyboardRoute.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(keyboardRoute.waitForExistence(timeout: 5))
        keyboardRoute.tap()

        XCTAssertTrue(app.staticTexts["Hardware Keyboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Software Keyboard"].exists)
        XCTAssertTrue(app.staticTexts["Accessory Bar"].exists)
        XCTAssertTrue(app.switches["Keep terminal size"].exists)
        XCTAssertTrue(app.switches["Show dismiss button"].exists)
        XCTAssertTrue(app.buttons["Customize Accessory Bar"].exists)
        XCTAssertTrue(app.buttons["Custom Actions"].exists)
        XCTAssertFalse(app.switches["Keep terminal size when keyboard opens"].exists)
        XCTAssertFalse(app.switches["Show keyboard dismiss button"].exists)
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
