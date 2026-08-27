#if os(iOS)
import XCTest

final class ServerDuplicateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDuplicateOpensPrefilledAddDraftAndCancelClosesIt() {
        let app = launchHarness()
        defer { app.terminate() }

        let duplicate = app.buttons["vvterm.serverDuplicateTest.action"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10))
        duplicate.tap()

        XCTAssertTrue(app.navigationBars["Add Server"].waitForExistence(timeout: 10))
        assertPrefilledDraft(in: app)
        XCTAssertTrue(app.buttons["Add"].exists)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(
            app.textFields["vvterm.serverForm.name"].waitForNonExistence(timeout: 5)
        )
        XCTAssertTrue(duplicate.exists)
    }

    @MainActor
    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-server-duplicate-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func assertPrefilledDraft(in app: XCUIApplication) {
        let name = app.textFields["vvterm.serverForm.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "DEV-397 UI Test Source Copy")

        let host = app.textFields["vvterm.serverForm.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        XCTAssertEqual(host.value as? String, "duplicate-test.example.com")
    }
}
#endif
