#if os(macOS)
import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testActionableSyncPageShowsServicesAndManualAction() {
        let app = launchHarness(syncEnabled: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["App Data — iCloud"].exists)
        XCTAssertTrue(app.staticTexts["Credentials and SSH Keys — iCloud Keychain"].exists)
        XCTAssertTrue(app.staticTexts["Up to Date"].exists)

        let syncNow = app.buttons["vvterm.settings.sync.syncNow.primary"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 5))
        syncNow.click()
        XCTAssertTrue(
            app.staticTexts["vvterm.settings.sync.lastSuccessful.value"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testCredentialRemovalUsesNativeConfirmation() {
        let app = launchHarness(syncEnabled: false)
        defer { app.terminate() }

        let remove = app.buttons["vvterm.settings.sync.removeCredentials"]
        for _ in 0..<6 where !remove.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.isEnabled)
        remove.click()

        XCTAssertTrue(app.buttons["Remove from iCloud Keychain"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    @MainActor
    private func launchHarness(syncEnabled: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-sync-settings-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-iCloudSyncEnabled", syncEnabled ? "YES" : "NO",
        ]
        if !syncEnabled {
            app.launchArguments.append("--vvterm-ui-test-sync-settings-disabled")
        }
        app.launch()
        return app
    }
}
#endif
