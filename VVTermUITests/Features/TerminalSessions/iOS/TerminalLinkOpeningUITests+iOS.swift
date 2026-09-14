#if os(iOS)
import XCTest

final class TerminalLinkOpeningUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testPlainLinkConfirmationCanCancelAndOpen() throws {
        let app = launchKeyboardHarness(floatingControlArguments: ["--vvterm-ui-test-terminal-link-fixture"])
        let terminal = waitForTerminal(in: app)
        let point = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0))
            .withOffset(CGVector(dx: 0, dy: (diagnosticMetrics(in: app)["linkCellHeight"] ?? 16) * 24.5))
        point.tap()
        let alert = app.alerts["Open Link"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), diagnosticsText(in: app))
        XCTAssertTrue(alert.staticTexts["https://example.com/visible"].exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(diagnosticsText(in: app).contains("openedLink=none"))
        point.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Open"].tap()
        wait(for: app.staticTexts["vvterm.keyboardTest.diagnostics"], labelContaining: "openedLink=https://example.com/visible", timeout: 5, diagnostics: diagnosticsText(in: app))
    }

    @MainActor
    func testLinkHitTestingPreservesCapturedTapsTypingAndScroll() throws {
        let app = launchKeyboardHarness(simulatesTerminalMouseCapture: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "mouseCaptured=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        terminal.tap()
        waitForMouseClickCounts(presses: 1, releases: 1, in: app)
        terminal.typeText("x")
        wait(for: diagnostics, labelContaining: "inputHex=78", timeout: 5, diagnostics: diagnosticsText(in: app))
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        waitForDiagnosticMetrics(in: app) { ($0["mouseScrollReports"] ?? 0) > 0 }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)
    }

    @MainActor
    func testCapturedLongPressDoesNotSendLinkProbeMotion() throws {
        let app = launchKeyboardHarness(
            simulatesTerminalMouseCapture: true,
            floatingControlArguments: ["--vvterm-ui-test-terminal-mouse-motion", "--vvterm-ui-test-terminal-link-fixture"]
        )
        let terminal = waitForTerminal(in: app)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0))
            .withOffset(CGVector(dx: 0, dy: (diagnosticMetrics(in: app)["linkCellHeight"] ?? 16) * 24.5))
            .press(forDuration: 0.6)
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        XCTAssertEqual(diagnosticMetrics(in: app)["mouseMotionReports"], 0, diagnosticsText(in: app))
        assertMouseClickCountsRemain(presses: 0, releases: 0, in: app)
    }

    @MainActor
    func testFileLinkWithoutServerHandlerShowsError() throws {
        let app = launchKeyboardHarness(floatingControlArguments: ["--vvterm-ui-test-terminal-link-fixture"])
        let terminal = waitForTerminal(in: app)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0))
            .withOffset(CGVector(dx: 0, dy: (diagnosticMetrics(in: app)["linkCellHeight"] ?? 16) * 26.5)).tap()
        let alert = app.alerts["Open Link"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), diagnosticsText(in: app))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "file://remote/tmp/example.txt")).firstMatch.exists)
        alert.buttons["Open"].tap()
        XCTAssertTrue(app.alerts["Unable to Open Link"].waitForExistence(timeout: 5))
        XCTAssertTrue(diagnosticsText(in: app).contains("openedLink=none"))
    }

    @MainActor
    func testOSC8LinkShowsItsActualDestination() throws {
        let app = launchKeyboardHarness(floatingControlArguments: ["--vvterm-ui-test-terminal-link-fixture"])
        let terminal = waitForTerminal(in: app)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0))
            .withOffset(CGVector(dx: 0, dy: (diagnosticMetrics(in: app)["linkCellHeight"] ?? 16) * 25.5)).tap()
        let alert = app.alerts["Open Link"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), diagnosticsText(in: app))
        XCTAssertTrue(alert.staticTexts["https://example.com/actual"].exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(diagnosticsText(in: app).contains("openedLink=none"))
    }
}
#endif
