#if os(macOS)
import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncPageShowsCompactHeroSummariesAndDetails() {
        let app = launchHarness(syncEnabled: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitForExistence(timeout: 10))
        let hero = app.descendants(matching: .any)["vvterm.settings.sync.statusHero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.value.debugDescription.contains("Up to Date"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last synced")).firstMatch.exists)
        XCTAssertLessThan(hero.frame.height, 100)
        let appData = app.descendants(matching: .any)["vvterm.settings.sync.data.app"]
        XCTAssertTrue(appData.exists)
        XCTAssertTrue(appData.label.contains("2 workspaces · 7 servers · 3 custom themes"))
        let credentials = app.descendants(matching: .any)[
            "vvterm.settings.sync.data.credentials"
        ]
        XCTAssertTrue(credentials.exists)
        XCTAssertTrue(credentials.label.contains("6 server credentials · 4 SSH keys"))
        XCTAssertFalse(app.staticTexts["On This Device"].exists)
        XCTAssertFalse(app.buttons["Advanced"].exists)

        let syncNow = app.buttons["vvterm.settings.sync.action.primary"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sync Now")).count, 1)
        syncNow.click()

        let detailsButton = app.buttons["vvterm.settings.sync.detailsButton"]
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 5))
        detailsButton.click()
        XCTAssertTrue(app.staticTexts["iCloud Sync Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)[
            "vvterm.settings.sync.details.workspaces"
        ].exists)
        XCTAssertTrue(app.descendants(matching: .any)[
            "vvterm.settings.sync.details.serverCredentials"
        ].exists)
        XCTAssertTrue(app.descendants(matching: .any)[
            "vvterm.settings.sync.details.openTerminals"
        ].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.details.lastSuccessful"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["vvterm.settings.sync.copyDiagnostics"].exists)
    }

    @MainActor
    func testCredentialRemovalUsesNativeConfirmation() {
        let app = launchHarness(syncEnabled: false)
        defer { app.terminate() }

        let hero = app.descendants(matching: .any)["vvterm.settings.sync.statusHero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.value.debugDescription.contains("Sync is Off"))
        XCTAssertFalse(app.staticTexts["Existing iCloud data is not deleted."].exists)
        XCTAssertFalse(app.buttons["vvterm.settings.sync.action.primary"].exists)

        let detailsButton = app.buttons["vvterm.settings.sync.detailsButton"]
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 5))
        detailsButton.click()
        XCTAssertTrue(app.staticTexts["iCloud Sync Details"].waitForExistence(timeout: 5))

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
