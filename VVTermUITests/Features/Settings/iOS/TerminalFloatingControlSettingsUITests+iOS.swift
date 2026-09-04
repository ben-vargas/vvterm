#if os(iOS)
import XCTest

final class TerminalFloatingControlSettingsUITests: XCTestCase {
    @MainActor
    func testSettingsShowsLivePreviewAndTextProMarkers() {
        let app = launchApp()
        defer { app.terminate() }

        openFloatingControlSettings(in: app)

        let preview = app.descendants(matching: .any)[
            "vvterm.settings.floatingInputControl.preview"
        ]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.value as? String, "Compact Buttons")
        let radial = app.buttons[
            "vvterm.settings.floatingInputControl.style.radial"
        ]
        XCTAssertTrue(radial.waitForExistence(timeout: 5))
        XCTAssertTrue(radial.label.contains("Pro"))
    }

    @MainActor
    func testFreeUserTappingRadialShowsProAlert() {
        let app = launchApp()
        defer { app.terminate() }

        openFloatingControlSettings(in: app)
        let radial = app.buttons[
            "vvterm.settings.floatingInputControl.style.radial"
        ]
        XCTAssertTrue(radial.waitForExistence(timeout: 5))
        radial.tap()

        XCTAssertTrue(app.alerts["Floating Input Control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Upgrade to Pro"].exists)
    }

    @MainActor
    func testPreviewCanAttachToSideAndRestoreNearIt() {
        let app = launchApp()
        defer { app.terminate() }

        openFloatingControlSettings(in: app)

        let preview = app.descendants(matching: .any)[
            "vvterm.settings.floatingInputControl.preview"
        ]
        let keyboard = app.buttons[
            "vvterm.settings.floatingInputControl.previewButton.keyboard"
        ]
        let edgeHandle = app.buttons[
            "vvterm.settings.floatingInputControl.previewEdgeHandle"
        ]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        if edgeHandle.waitForExistence(timeout: 0.5) {
            edgeHandle.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: preview.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5)
                )
            )

        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        XCTAssertTrue(edgeHandle.waitForExistence(timeout: 5))
        XCTAssertLessThan(edgeHandle.frame.midX, preview.frame.midX)

        edgeHandle.tap()

        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(edgeHandle.waitForNonExistence(timeout: 5))
        XCTAssertLessThan(
            keyboard.frame.midX,
            preview.frame.midX,
            "The preview control did not return near the selected side."
        )
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        let welcomeContinue = app.buttons["Continue"]
        if welcomeContinue.waitForExistence(timeout: 1) {
            welcomeContinue.tap()
        }
        return app
    }

    @MainActor
    private func openFloatingControlSettings(in app: XCUIApplication) {
        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let keyboardRoute = app.buttons["vvterm.settings.route.keyboardAndInput"]
        XCTAssertTrue(scrollToHittable(keyboardRoute, in: app))
        keyboardRoute.tap()

        let floatingControl = app.buttons["Floating Input Control"]
        XCTAssertTrue(scrollToHittable(floatingControl, in: app))
        floatingControl.tap()
    }

    @MainActor
    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable {
            return true
        }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists, element.isHittable {
                return true
            }
        }
        return false
    }
}
#endif
