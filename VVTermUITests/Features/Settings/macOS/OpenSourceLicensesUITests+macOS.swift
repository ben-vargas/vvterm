#if os(macOS)
import XCTest

final class OpenSourceLicensesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAboutWindowOpensTheSharedLicensePresentation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.privacyModeEnabled", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let applicationMenu = app.menuBars.menuBarItems["VVTerm"]
        XCTAssertTrue(applicationMenu.waitForExistence(timeout: 5))
        applicationMenu.click()

        let aboutItem = app.menuItems["About VVTerm"]
        XCTAssertTrue(aboutItem.waitForExistence(timeout: 5))
        aboutItem.click()

        let licenses = app.buttons["vvterm.about.openSourceLicenses"]
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        licenses.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.openSourceLicenses"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.openSourceLicenses.thankYou"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["vvterm.openSourceLicenses.project.ghostty"]
                .waitForExistence(timeout: 5)
        )

        let close = app.buttons["vvterm.openSourceLicenses.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        XCTAssertTrue(licenses.isHittable)
    }
}
#endif
