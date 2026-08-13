#if os(iOS)
import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncPageStaysCompactAndRecordsManualSuccess() {
        let app = launchHarness(syncEnabled: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitForExistence(timeout: 10))
        let status = app.descendants(matching: .any)["vvterm.settings.sync.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Sync Status"))
        XCTAssertTrue(status.value.debugDescription.contains("Up to Date"))
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.synced"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.local"].exists
        )
        XCTAssertFalse(app.staticTexts["App Data — iCloud"].exists)

        let notYet = app.staticTexts["vvterm.settings.sync.lastSuccessful.empty"]
        XCTAssertTrue(notYet.exists)

        let syncNow = app.buttons["vvterm.settings.sync.syncNow.primary"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 5))
        XCTAssertLessThan(syncNow.frame.minY - status.frame.maxY, 120)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sync Now")).count, 1)
        syncNow.tap()

        let predicate = NSPredicate(format: "exists == false")
        expectation(for: predicate, evaluatedWith: notYet)
        waitForExpectations(timeout: 5)
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
        advanced.tap()

        let remove = app.buttons["vvterm.settings.sync.removeCredentials"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.isEnabled)
        remove.tap()

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
