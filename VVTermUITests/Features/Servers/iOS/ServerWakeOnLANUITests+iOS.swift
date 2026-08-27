#if os(iOS)
import XCTest

final class ServerWakeOnLANUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWakeActionIsAvailableWithoutSavedConfiguration() {
        let app = launchHarness()
        defer { app.terminate() }

        let row = app.descendants(matching: .any)["vvterm.serverDuplicateTest.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1)

        let wake = app.buttons[
            "vvterm.serverList.wake.4BEE9E2E-E2CF-438C-A44C-B2391D0606E5"
        ]
        XCTAssertTrue(wake.waitForExistence(timeout: 5))
        wake.tap()

        let actionCount = app.staticTexts["vvterm.serverWakeTest.actionCount"]
        XCTAssertTrue(actionCount.waitForExistence(timeout: 5))
        XCTAssertEqual(actionCount.label, "1")
    }

    @MainActor
    func testAutoWakeSettingIsInAdvancedSection() {
        let app = launchHarness()
        defer { app.terminate() }

        let row = app.descendants(matching: .any)["vvterm.serverDuplicateTest.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1)
        app.buttons["Edit"].tap()

        XCTAssertTrue(app.navigationBars["Edit Server"].waitForExistence(timeout: 10))
        let advanced = app.descendants(matching: .any)["vvterm.serverForm.advanced"]
        let autoWake = app.switches["vvterm.serverForm.wakeOnLAN.enabled"]
        for _ in 0..<12 where !autoWake.isHittable {
            app.swipeUp()
        }

        XCTAssertTrue(advanced.exists)
        XCTAssertTrue(autoWake.isHittable)
        XCTAssertEqual(autoWake.label, "Auto Wake-on-LAN")
        XCTAssertGreaterThan(autoWake.frame.minY, advanced.frame.minY)
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
}
#endif
