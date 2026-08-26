#if os(iOS)
import XCTest

final class OpenSourceLicensesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAboutSettingsOpensBundledLicenseText() {
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
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let about = app.buttons["vvterm.settings.route.aboutAndSupport"]
        XCTAssertTrue(about.waitForExistence(timeout: 8))
        about.tap()

        let licenses = app.buttons["vvterm.settings.openSourceLicenses"]
        XCTAssertTrue(scrollToHittable(licenses, in: app))
        licenses.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.openSourceLicenses"]
                .waitForExistence(timeout: 8)
        )
        let close = app.buttons["vvterm.openSourceLicenses.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.openSourceLicenses.thankYou"]
                .waitForExistence(timeout: 5)
        )

        let ghostty = app.buttons["vvterm.openSourceLicenses.project.ghostty"]
        XCTAssertTrue(ghostty.waitForExistence(timeout: 5))
        ghostty.tap()

        XCTAssertTrue(
            app.staticTexts["vvterm.openSourceLicenses.legalText"]
                .waitForExistence(timeout: 5)
        )

        close.tap()
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        XCTAssertTrue(licenses.isHittable)
    }

    @MainActor
    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable {
            return true
        }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists, element.isHittable {
                return true
            }
        }
        return false
    }
}
#endif
