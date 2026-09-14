#if os(iOS)
import XCTest

final class CustomThemeDuplicateUITests: XCTestCase {
    @MainActor
    func testDuplicateCreatesCopyAndKeepsOriginalActive() {
        let app = launchHarness()
        defer { app.terminate() }
        app.buttons["vvterm.customTheme.actions.00000000-0000-0000-0000-000000000235"].tap()
        let duplicate = app.buttons["Duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.tap()
        XCTAssertTrue(app.staticTexts["Original 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Active").count, 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Duplicate created, original active"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDuplicateInvalidThemeShowsErrorWithoutCreatingCopy() {
        let app = launchHarness()
        defer { app.terminate() }
        app.buttons["vvterm.customTheme.actions.00000000-0000-0000-0000-000000000236"].tap()
        app.buttons["Duplicate"].tap()
        XCTAssertTrue(app.alerts["Custom Theme"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.staticTexts["Broken 2"].exists)
        XCTAssertTrue(app.staticTexts["Broken"].exists)
    }

    @MainActor
    private func launchHarness() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--vvterm-ui-test-custom-theme-duplicate", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["vvterm.customTheme.actions.00000000-0000-0000-0000-000000000235"].waitForExistence(timeout: 10))
        return app
    }
}
#endif
