#if os(iOS)
import XCTest

final class TerminalZenModeUITests: XCTestCase {
    @MainActor
    func testRealTerminalLauncherOpensZenPanel() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.zenTest.terminalSurface"]
                .waitForExistence(timeout: 15)
        )
        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["vvterm.terminal.floating.voiceInput"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(launcher.isHittable)
        XCTAssertEqual(launcher.frame.width, launcher.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(launcher.frame.width, 48)
        launcher.tap()

        XCTAssertTrue(
            app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5),
            "Zen launcher remained visible but did not open the control panel"
        )
    }

    @MainActor
    func testOpeningKeyboardHidesIdleFloatingControlInZenMode() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "--vvterm-ui-test-simulate-keyboard-frames",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.zenTest.terminalSurface"]
                .waitForExistence(timeout: 15)
        )
        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        let control = app.descendants(matching: .any)[
            "vvterm.terminal.floatingInputControl"
        ]
        let keyboard = app.buttons["vvterm.terminal.floating.keyboard"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        keyboard.tap()

        XCTAssertTrue(control.waitForNonExistence(timeout: 5))
        XCTAssertTrue(launcher.exists)
    }

    @MainActor
    func testZenPanelShowsAndHidesFloatingControlWithoutDuplicateInputActions() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        app.launch()

        let chrome = app.buttons["vvterm.zenTest.chrome"]
        XCTAssertTrue(chrome.waitForExistence(timeout: 5))

        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        let floatingVoice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(floatingVoice.waitForExistence(timeout: 5))
        XCTAssertTrue(chrome.waitForNonExistence(timeout: 5))

        launcher.tap()
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5))
        let floatingToggle = app.switches[
            "vvterm.terminal.zen.floatingInputControl"
        ]
        XCTAssertTrue(floatingToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(floatingToggle.value as? String, "1")
        XCTAssertFalse(app.buttons["vvterm.terminal.zen.keyboard"].exists)
        XCTAssertFalse(app.buttons["vvterm.terminal.zen.voiceInput"].exists)
        XCTAssertFalse(app.buttons["vvterm.terminal.zen.system.escape"].exists)
        XCTAssertFalse(app.buttons["vvterm.terminal.zen.system.tab"].exists)

        floatingToggle.tap()
        XCTAssertTrue(floatingVoice.waitForNonExistence(timeout: 5))
        XCTAssertEqual(floatingToggle.value as? String, "0")

        floatingToggle.tap()
        XCTAssertTrue(floatingVoice.waitForExistence(timeout: 5))
        XCTAssertEqual(floatingToggle.value as? String, "1")
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.view.files"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.newTab"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.settings"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.editServer"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.back"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.disconnect"].exists)

        app.buttons["vvterm.terminal.zen.view.files"].tap()
        XCTAssertTrue(app.buttons["vvterm.zen.controls"].exists)

        let exitZenMode = app.buttons["vvterm.terminal.exitZenMode"]
        XCTAssertTrue(exitZenMode.waitForExistence(timeout: 5))
        if !exitZenMode.isHittable {
            app.scrollViews["vvterm.terminal.zenPanel"].swipeUp()
        }
        XCTAssertTrue(exitZenMode.isHittable)
        exitZenMode.tap()

        XCTAssertTrue(chrome.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForNonExistence(timeout: 5)
        )
    }

    @MainActor
    func testEdgeHiddenControlRemainsEnabledInZenPanel() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "--vvterm-ui-test-floating-control-hidden-left",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.zenTest.terminalSurface"]
                .waitForExistence(timeout: 15)
        )
        app.buttons["vvterm.terminal.moreMenu"].tap()
        app.buttons["vvterm.terminal.enterZenMode"].tap()

        let edgeHandle = app.buttons["vvterm.terminal.floating.edgeHandle"]
        XCTAssertTrue(edgeHandle.waitForExistence(timeout: 5))

        app.buttons["vvterm.zen.controls"].tap()
        let floatingToggle = app.switches[
            "vvterm.terminal.zen.floatingInputControl"
        ]
        XCTAssertTrue(floatingToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(floatingToggle.value as? String, "1")

        floatingToggle.tap()
        XCTAssertEqual(floatingToggle.value as? String, "0")
        XCTAssertTrue(edgeHandle.waitForNonExistence(timeout: 5))

        floatingToggle.tap()
        XCTAssertEqual(floatingToggle.value as? String, "1")
        XCTAssertTrue(edgeHandle.waitForExistence(timeout: 5))
    }

    @MainActor
    func testActiveVoiceStaysVisibleWhenZenPanelHidesIdleControl() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.zenTest.terminalSurface"]
                .waitForExistence(timeout: 15)
        )
        app.buttons["vvterm.terminal.moreMenu"].tap()
        app.buttons["vvterm.terminal.enterZenMode"].tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()

        let stop = app.buttons["vvterm.terminal.floating.stopVoice"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(launcher.exists)

        launcher.tap()
        let floatingToggle = app.switches[
            "vvterm.terminal.zen.floatingInputControl"
        ]
        XCTAssertTrue(floatingToggle.waitForExistence(timeout: 5))
        floatingToggle.tap()
        XCTAssertEqual(floatingToggle.value as? String, "0")
        XCTAssertTrue(stop.exists)
        launcher.tap()

        stop.tap()
        let sendReturn = app.buttons["vvterm.terminal.floating.return"]
        XCTAssertTrue(sendReturn.waitForExistence(timeout: 5))
        sendReturn.tap()

        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sendReturn.waitForNonExistence(timeout: 5))
        XCTAssertTrue(voice.waitForNonExistence(timeout: 5))

        launcher.tap()
        XCTAssertTrue(floatingToggle.waitForExistence(timeout: 5))
        floatingToggle.tap()
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
    }
}
#endif
