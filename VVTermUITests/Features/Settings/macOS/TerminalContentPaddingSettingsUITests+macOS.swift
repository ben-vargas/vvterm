#if os(macOS)
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
            controls.reset.click()
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
        controls.reset.click()
        XCTAssertTrue(scrollToHittable(controls.horizontal, in: app))
        XCTAssertEqual(controls.horizontal.value as? String, "0 pt")
        XCTAssertTrue(scrollToHittable(controls.vertical, in: app))
        XCTAssertEqual(controls.vertical.value as? String, "0 pt")
        app.terminate()
    }

    @MainActor
    func testAppearanceSlidersShowOneLabelAndKeepAccessibleNames() {
        let app = launchApp()
        defer { app.terminate() }
        let controls = openPaddingControls(in: app)
        let fontSize = app.sliders["vvterm.settings.appearance.fontSize"]
        for (slider, title) in [(fontSize, "Size"), (controls.horizontal, "Horizontal"),
                                (controls.vertical, "Vertical")] {
            XCTAssertTrue(scrollToHittable(slider, in: app))
            XCTAssertEqual(slider.label, title)
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", title)).count, 1)
        }
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.privacyModeEnabled", "NO",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openPaddingControls(in app: XCUIApplication) -> PaddingControls {
        app.typeKey(",", modifierFlags: .command)
        let settingsRoot = app.descendants(matching: .any)["vvterm.settings.root"]
        XCTAssertTrue(settingsRoot.waitForExistence(timeout: 10))

        let appearance = app.descendants(matching: .any)[
            "vvterm.settings.route.terminalAppearance"
        ]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.click()

        return PaddingControls(
            horizontal: app.sliders["vvterm.settings.contentPadding.horizontal"],
            vertical: app.sliders["vvterm.settings.contentPadding.vertical"],
            reset: app.buttons["vvterm.settings.contentPadding.reset"]
        )
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
