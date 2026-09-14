#if os(macOS)
import XCTest

final class CustomThemeDuplicateUITests: XCTestCase {
    @MainActor
    func testContextMenuDuplicateKeepsOriginalActive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--vvterm-ui-test-custom-theme-duplicate", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let source = app.staticTexts["Original"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.rightClick()
        let duplicate = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.click()
        XCTAssertTrue(app.staticTexts["Original 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(source.exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Active").count, 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Duplicate created, original active"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
