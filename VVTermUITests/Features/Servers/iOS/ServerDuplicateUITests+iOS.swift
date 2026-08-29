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

        let row = app.descendants(matching: .any)["vvterm.serverDuplicateTest.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeRight()

        let duplicate = app.buttons[
            "vvterm.serverList.duplicate.4BEE9E2E-E2CF-438C-A44C-B2391D0606E5"
        ]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10))
        duplicate.tap()

        XCTAssertTrue(app.navigationBars["Add Server"].waitForExistence(timeout: 10))
        assertPrefilledDraft(in: app)
        XCTAssertTrue(app.buttons["Add"].exists)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(
            app.textFields["vvterm.serverForm.name"].waitForNonExistence(timeout: 5)
        )
        XCTAssertTrue(row.exists)
    }

    @MainActor
    func testIconPickerKeepsManualChoiceAndCanSelectAutomatic() {
        let app = launchHarness()
        defer { app.terminate() }

        let row = app.descendants(matching: .any)["vvterm.serverDuplicateTest.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeRight()
        let duplicate = app.buttons[
            "vvterm.serverList.duplicate.4BEE9E2E-E2CF-438C-A44C-B2391D0606E5"
        ]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10))
        duplicate.tap()

        let picker = app.descendants(matching: .any)["vvterm.serverIcon.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue((picker.value as? String)?.contains("Database") == true)
        picker.tap()

        let database = app.descendants(matching: .any)["vvterm.serverIcon.custom.database"]
        XCTAssertTrue(database.waitForExistence(timeout: 5))
        XCTAssertTrue(database.isSelected)

        let appleDevices = app.descendants(matching: .any)[
            "vvterm.serverIcon.section.appleDevices"
        ]
        scrollUp(in: app, untilVisible: appleDevices)
        XCTAssertTrue(isVisible(appleDevices, in: app))
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.serverIcon.custom.mac_studio"].exists
        )

        let operatingSystems = app.descendants(matching: .any)[
            "vvterm.serverIcon.section.operatingSystems"
        ]
        scrollUp(in: app, untilVisible: operatingSystems)
        XCTAssertTrue(isVisible(operatingSystems, in: app))
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.serverIcon.custom.ubuntu"].exists
        )

        let automatic = app.descendants(matching: .any)["vvterm.serverIcon.automatic"]
        scrollDown(in: app, untilVisible: automatic)
        XCTAssertTrue(isVisible(automatic, in: app))
        automatic.tap()
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
        return app
    }

    @MainActor
    private func scrollUp(in app: XCUIApplication, untilVisible element: XCUIElement) {
        for _ in 0..<8 where !isVisible(element, in: app) {
            app.swipeUp()
        }
    }

    @MainActor
    private func scrollDown(in app: XCUIApplication, untilVisible element: XCUIElement) {
        for _ in 0..<8 where !isVisible(element, in: app) {
            app.swipeDown()
        }
    }

    @MainActor
    private func isVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        element.exists && !element.frame.isEmpty && element.frame.intersects(app.frame)
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
