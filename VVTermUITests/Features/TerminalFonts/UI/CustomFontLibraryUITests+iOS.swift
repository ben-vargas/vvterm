#if os(iOS)
import XCTest

final class CustomFontLibraryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFontSettingsOrderAndIntentBasedProGate() throws {
        let app = launchApp()
        defer { app.terminate() }

        openTerminalAppearance(in: app, waitForFreePlan: true)

        let fontSize = app.sliders["vvterm.settings.appearance.fontSize"]
        let cjkFont = app.descendants(matching: .any)[
            "vvterm.settings.appearance.cjkFont"
        ]
        let customFonts = app.buttons["vvterm.settings.appearance.customFonts"]

        XCTAssertTrue(fontSize.waitForExistence(timeout: 5))
        XCTAssertTrue(cjkFont.waitForExistence(timeout: 5))
        XCTAssertTrue(customFonts.waitForExistence(timeout: 5))
        XCTAssertLessThan(fontSize.frame.minY, cjkFont.frame.minY)
        XCTAssertLessThan(cjkFont.frame.minY, customFonts.frame.minY)
        XCTAssertFalse(customFonts.label.localizedCaseInsensitiveContains("pro"))

        customFonts.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.customFonts.page"]
                .waitForExistence(timeout: 5)
        )

        let importFont = app.buttons["vvterm.settings.customFonts.import"]
        XCTAssertTrue(importFont.waitForExistence(timeout: 5))
        importFont.tap()

        let proAlert = app.alerts["Custom Fonts"]
        XCTAssertTrue(proAlert.waitForExistence(timeout: 5))
        let upgrade = proAlert.buttons["Upgrade to Pro"]
        XCTAssertTrue(upgrade.exists)
        upgrade.tap()

        let comparisonTexts = app.staticTexts.matching(
            identifier: "vvterm.pro.comparison"
        )
        let customActionsBenefit = comparisonTexts.matching(
            NSPredicate(format: "label == %@", "Custom actions")
        ).firstMatch
        let customFontsBenefit = comparisonTexts.matching(
            NSPredicate(format: "label == %@", "Custom Fonts")
        ).firstMatch
        let cjkBenefit = comparisonTexts.matching(
            NSPredicate(format: "label == %@", "CJK Font")
        ).firstMatch
        XCTAssertTrue(customActionsBenefit.waitForExistence(timeout: 5))
        XCTAssertTrue(customFontsBenefit.exists)
        XCTAssertTrue(cjkBenefit.exists)
        XCTAssertLessThan(customActionsBenefit.frame.minY, customFontsBenefit.frame.minY)
        XCTAssertLessThan(customFontsBenefit.frame.minY, cjkBenefit.frame.minY)
    }

    @MainActor
    func testLibraryOpensFromTerminalAppearanceAndReturns() throws {
        let app = launchApp()
        defer { app.terminate() }

        openTerminalAppearance(in: app)

        let customFonts = app.buttons["vvterm.settings.appearance.customFonts"]
        XCTAssertTrue(scrollToHittable(customFonts, in: app))
        customFonts.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.customFonts.page"]
                .waitForExistence(timeout: 5)
        )
        let back = app.navigationBars["Custom Fonts"].buttons.firstMatch
        XCTAssertTrue(back.exists)
        back.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.page.terminalAppearance"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testFreeCJKOptionsAreSingleRowProChoicesAndStayLocked() throws {
        let app = launchApp()
        defer { app.terminate() }

        openTerminalAppearance(in: app, waitForFreePlan: true)

        let cjkFont = app.buttons["vvterm.settings.appearance.cjkFont"]
        XCTAssertTrue(cjkFont.waitForExistence(timeout: 5))
        XCTAssertTrue(cjkFont.isHittable)
        let initialSelection = cjkFont.label
        cjkFont.tap()

        let proOption = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "(Pro)"))
            .firstMatch
        XCTAssertTrue(proOption.waitForExistence(timeout: 5))
        XCTAssertNotEqual(proOption.label, "(Pro)")
        proOption.tap()
        XCTAssertEqual(cjkFont.label, initialSelection)
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
        return app
    }

    @MainActor
    private func openTerminalAppearance(
        in app: XCUIApplication,
        waitForFreePlan: Bool = false
    ) {
        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        if waitForFreePlan {
            let proRoute = app.buttons["vvterm.settings.route.pro"]
            XCTAssertTrue(proRoute.waitForExistence(timeout: 8))
            let freePlan = NSPredicate(format: "label CONTAINS[c] %@", "FREE")
            let expectation = XCTNSPredicateExpectation(
                predicate: freePlan,
                object: proRoute
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        }

        let terminalAppearance = app.buttons["vvterm.settings.route.terminalAppearance"]
        XCTAssertTrue(terminalAppearance.waitForExistence(timeout: 8))
        terminalAppearance.tap()
    }

    @MainActor
    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable {
            return true
        }
        for _ in 0..<6 {
            app.swipeUp()
            if element.exists, element.isHittable {
                return true
            }
        }
        return false
    }
}
#endif
