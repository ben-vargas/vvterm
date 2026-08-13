#if os(macOS)
import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncPageStaysCompactAndOffersOneManualAction() {
        let app = launchHarness(syncEnabled: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitForExistence(timeout: 10))
        let status = app.descendants(matching: .any)["vvterm.settings.sync.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.value.debugDescription.contains("Up to Date"))
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.synced"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.local"].exists
        )
        XCTAssertFalse(app.staticTexts["App Data — iCloud"].exists)

        let syncNow = app.buttons["vvterm.settings.sync.syncNow.primary"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sync Now")).count, 1)
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

        let advanced = app.buttons["vvterm.settings.sync.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.click()

        let remove = app.buttons["vvterm.settings.sync.removeCredentials"]
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
