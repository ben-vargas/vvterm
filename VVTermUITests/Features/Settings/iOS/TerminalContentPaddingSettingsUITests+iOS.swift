#if os(iOS)
import XCTest

final class TerminalContentPaddingSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPaddingPersistsAndResetRestoresZero() {
        var app = launchApp()
        var controls = openPaddingControls(in: app)

        XCTAssertTrue(scrollToHittable(controls.reset, in: app))
        if controls.reset.isEnabled {
            controls.reset.tap()
        }
        XCTAssertTrue(scrollToHittable(controls.horizontal, in: app))
        XCTAssertEqual(controls.horizontal.value as? String, "0 pt")
        controls.horizontal.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertEqual(controls.horizontal.value as? String, "16 pt")

        XCTAssertTrue(scrollToHittable(controls.vertical, in: app))
        XCTAssertEqual(controls.vertical.value as? String, "0 pt")
        controls.vertical.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertEqual(controls.vertical.value as? String, "24 pt")

        app.terminate()
        app = launchApp()
        controls = openPaddingControls(in: app)

        XCTAssertTrue(scrollToHittable(controls.horizontal, in: app))
        XCTAssertEqual(controls.horizontal.value as? String, "16 pt")
        XCTAssertTrue(scrollToHittable(controls.vertical, in: app))
        XCTAssertEqual(controls.vertical.value as? String, "24 pt")
        XCTAssertTrue(scrollToHittable(controls.reset, in: app))
        controls.reset.tap()
        XCTAssertTrue(scrollToHittable(controls.horizontal, in: app))
        XCTAssertEqual(controls.horizontal.value as? String, "0 pt")
        XCTAssertTrue(scrollToHittable(controls.vertical, in: app))
        XCTAssertEqual(controls.vertical.value as? String, "0 pt")
        app.terminate()
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
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
        return app
    }

    @MainActor
    private func openPaddingControls(in app: XCUIApplication) -> PaddingControls {
        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let appearance = app.buttons["vvterm.settings.route.terminalAppearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 8))
        appearance.tap()

        let horizontal = app.sliders["vvterm.settings.contentPadding.horizontal"]
        let vertical = app.sliders["vvterm.settings.contentPadding.vertical"]
        let reset = app.buttons["vvterm.settings.contentPadding.reset"]
        return PaddingControls(horizontal: horizontal, vertical: vertical, reset: reset)
    }

    @MainActor
    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable {
            return true
        }
        for _ in 0..<6 {
            app.swipeDown()
            if element.exists, element.isHittable {
                return true
            }
        }
        for _ in 0..<6 {
            app.swipeUp()
            if element.exists, element.isHittable {
                return true
            }
        }
        return false
    }

    private struct PaddingControls {
        let horizontal: XCUIElement
        let vertical: XCUIElement
        let reset: XCUIElement
    }
}
#endif
