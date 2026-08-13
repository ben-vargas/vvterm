#if os(iOS)
import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncPageShowsHeroActionSummariesAndDetails() {
        let app = launchHarness(syncEnabled: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitForExistence(timeout: 10))
        let hero = app.descendants(matching: .any)["vvterm.settings.sync.statusHero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.label.contains("Sync Status"))
        XCTAssertTrue(hero.value.debugDescription.contains("Up to Date"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last synced")).firstMatch.exists)
        XCTAssertGreaterThan(hero.frame.height, 80)
        XCTAssertLessThan(hero.frame.height, 180)

        let toggle = app.switches["vvterm.settings.sync.toggle"]
        XCTAssertTrue(toggle.exists)
        XCTAssertLessThan(toggle.frame.minY - hero.frame.maxY, 100)
        XCTAssertFalse(app.staticTexts["Keep your setup on all devices."].exists)
        XCTAssertFalse(app.staticTexts["Use data stored on this device."].exists)

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
        XCTAssertLessThan(syncNow.frame.minY - hero.frame.maxY, 70)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sync Now")).count, 1)
        syncNow.tap()

        let detailsButton = app.buttons["vvterm.settings.sync.detailsButton"]
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 5))
        detailsButton.tap()
        XCTAssertTrue(app.staticTexts["iCloud Sync Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)[
            "vvterm.settings.sync.details.workspaces"
        ].exists)
        let serverCredentials = app.descendants(matching: .any)[
            "vvterm.settings.sync.details.serverCredentials"
        ]
        XCTAssertTrue(scrollToElement(serverCredentials, in: app))
        let openTerminals = app.descendants(matching: .any)[
            "vvterm.settings.sync.details.openTerminals"
        ]
        XCTAssertTrue(scrollToElement(openTerminals, in: app))
        let lastSuccessful = app.descendants(matching: .any)[
            "vvterm.settings.sync.details.lastSuccessful"
        ]
        XCTAssertTrue(scrollToElement(lastSuccessful, in: app))
        let copyDiagnostics = app.buttons["vvterm.settings.sync.copyDiagnostics"]
        XCTAssertTrue(scrollToElement(copyDiagnostics, in: app, requireHittable: true))
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
        detailsButton.tap()
        XCTAssertTrue(app.staticTexts["iCloud Sync Details"].waitForExistence(timeout: 5))

        let remove = app.buttons["vvterm.settings.sync.removeCredentials"]
        XCTAssertTrue(scrollToElement(remove, in: app, requireHittable: true))
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

    @MainActor
    private func scrollToElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        requireHittable: Bool = false
    ) -> Bool {
        func isReady() -> Bool {
            element.exists && (!requireHittable || element.isHittable)
        }

        if isReady() {
            return true
        }
        for _ in 0..<8 {
            app.swipeUp()
            if isReady() {
                return true
            }
        }
        return false
    }
}
#endif
