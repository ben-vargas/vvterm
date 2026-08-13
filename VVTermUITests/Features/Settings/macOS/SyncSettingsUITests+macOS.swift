#if os(macOS)
import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncPageShowsCompactStatusHeroAndShortDataRows() {
        let app = launchHarness(syncEnabled: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitForExistence(timeout: 10))
        let hero = app.descendants(matching: .any)["vvterm.settings.sync.statusHero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.value.debugDescription.contains("Up to Date"))
        XCTAssertLessThan(hero.frame.height, 100)
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.app"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.credentials"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.sessions"].exists
        )
        XCTAssertFalse(app.staticTexts["App Data — iCloud"].exists)

        let syncNow = app.buttons["vvterm.settings.sync.action.primary"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sync Now")).count, 1)
        syncNow.click()

        let advanced = app.buttons["vvterm.settings.sync.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.advanced.lastSuccessful"]
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
        XCTAssertTrue(app.staticTexts["Existing iCloud data is not deleted."].exists)
        XCTAssertFalse(app.buttons["vvterm.settings.sync.action.primary"].exists)

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
