#if os(iOS)
import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncPageShowsStatusHeroShortDataRowsAndOneManualAction() {
        let app = launchHarness(syncEnabled: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitForExistence(timeout: 10))
        let hero = app.descendants(matching: .any)["vvterm.settings.sync.statusHero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.label.contains("Sync Status"))
        XCTAssertTrue(hero.value.debugDescription.contains("Up to Date"))
        XCTAssertGreaterThan(hero.frame.height, 80)
        XCTAssertLessThan(hero.frame.height, 180)

        let toggle = app.switches["vvterm.settings.sync.toggle"]
        XCTAssertTrue(toggle.exists)
        XCTAssertLessThan(toggle.frame.minY - hero.frame.maxY, 100)

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.app"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.credentials"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.sync.data.sessions"].exists
        )
        XCTAssertTrue(app.staticTexts["Servers & Settings"].exists)
        XCTAssertTrue(app.staticTexts["Passwords & SSH Keys"].exists)
        XCTAssertTrue(app.staticTexts["Active Sessions"].exists)
        XCTAssertFalse(app.staticTexts["App Data — iCloud"].exists)
        XCTAssertFalse(
            app.staticTexts[
                "Workspaces, servers, settings, credentials, and SSH keys sync with iCloud."
            ].exists
        )

        let syncNow = app.buttons["vvterm.settings.sync.action.primary"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sync Now")).count, 1)
        syncNow.tap()

        let advanced = app.buttons["vvterm.settings.sync.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
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
