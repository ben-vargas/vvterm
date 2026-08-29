#if os(macOS)
import XCTest

final class ServerDuplicateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDuplicateOpensPrefilledAddDraftAndCancelClosesIt() {
        let app = launchHarness()
        defer { app.terminate() }

        let duplicate = app.buttons["vvterm.serverDuplicateTest.action"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10))
        duplicate.click()

        XCTAssertTrue(app.staticTexts["Add Server"].waitForExistence(timeout: 10))
        assertPrefilledDraft(in: app)
        XCTAssertTrue(app.buttons["Add"].exists)

        app.buttons["Cancel"].click()
        XCTAssertTrue(
            app.textFields["vvterm.serverForm.name"].waitForNonExistence(timeout: 5)
        )
        XCTAssertTrue(duplicate.exists)
    }

    @MainActor
    func testIconPickerKeepsManualChoiceAndCanSelectAutomatic() {
        let app = launchHarness()
        defer { app.terminate() }

        let duplicate = app.buttons["vvterm.serverDuplicateTest.action"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10))
        duplicate.click()

        let picker = app.descendants(matching: .any)["vvterm.serverIcon.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue((picker.value as? String)?.contains("Database") == true)
        picker.click()

        let database = app.buttons["vvterm.serverIcon.custom.database"]
        XCTAssertTrue(database.waitForExistence(timeout: 5))
        XCTAssertTrue(database.isSelected)

        let automatic = app.descendants(matching: .any)["vvterm.serverIcon.automatic"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue((picker.value as? String)?.contains("Automatic") == true)
        let detectedMacBook = NSPredicate { evaluatedObject, _ in
            guard let picker = evaluatedObject as? XCUIElement,
                  let value = picker.value as? String else { return false }
            return value.contains("Detected: MacBook Pro")
        }
        expectation(for: detectedMacBook, evaluatedWith: picker)
        waitForExpectations(timeout: 5)
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
        app.activate()
        let root = app.descendants(matching: .any)["vvterm.serverDuplicateTest.root"]
        if !root.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
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
