#if os(iOS)
import XCTest

final class TerminalSelectionStabilityUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testSelectionKeepsWritingToolsDisabled() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        let height = try requiredDiagnosticMetric("linkCellHeight", in: app)
        XCTAssertEqual(try requiredDiagnosticMetric("writingToolsDisabled", in: app), 1)
        terminal.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 20, dy: height * 20.5)).doubleTap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        XCTAssertEqual(try requiredDiagnosticMetric("writingToolsDisabled", in: app), 1)
        let rebuilds = try requiredDiagnosticMetric("inputRebuilds", in: app)
        app.buttons["vvterm.keyboardTest.selection.output"].tap()
        waitForDiagnosticMetrics(in: app, timeout: 15) { $0["selectionOutputRows"] == 80 }
        XCTAssertEqual(try requiredDiagnosticMetric("writingToolsDisabled", in: app), 1)
        XCTAssertGreaterThan(try requiredDiagnosticMetric("nativeSelectionLength", in: app), 0)
        XCTAssertEqual(try requiredDiagnosticMetric("inputRebuilds", in: app), rebuilds)
    }

    @MainActor
    func testSelectionSurvivesLiveOutputAndKeyboardLayoutChanges() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        let cellHeight = try requiredDiagnosticMetric("linkCellHeight", in: app)
        let point = terminal.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 20, dy: cellHeight * 20.5))
        point.doubleTap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        let selectedText = try selectionText(in: app)
        let initialY = try requiredDiagnosticMetric("nativeSelectionY", in: app)
        let rebuilds = try requiredDiagnosticMetric("inputRebuilds", in: app)
        app.buttons["vvterm.keyboardTest.selection.output"].tap()
        waitForDiagnosticMetrics(in: app, timeout: 15) { $0["selectionOutputRows"] == 80 }
        XCTAssertEqual(try selectionText(in: app), selectedText, diagnosticsText(in: app))
        XCTAssertEqual(try requiredDiagnosticMetric("nativeSelectionY", in: app), initialY)
        XCTAssertEqual(try requiredDiagnosticMetric("inputRebuilds", in: app), rebuilds)
        app.buttons["vvterm.keyboardTest.geometry.hidden"].tap()
        XCTAssertEqual(try selectionText(in: app), selectedText, diagnosticsText(in: app))
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        XCTAssertEqual(try selectionText(in: app), selectedText, diagnosticsText(in: app))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertEqual(try selectionText(in: app), selectedText, diagnosticsText(in: app))
        XCUIDevice.shared.orientation = .portrait
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        XCTAssertEqual(try selectionText(in: app), selectedText, diagnosticsText(in: app))
        XCTAssertEqual(try requiredDiagnosticMetric("inputRebuilds", in: app), rebuilds)
    }

    @MainActor
    func testNativeHandleDragStaysOnSelectedRowDuringLiveOutput() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        let height = try requiredDiagnosticMetric("linkCellHeight", in: app)
        let width = try requiredDiagnosticMetric("selectionCellWidth", in: app)
        let origin = terminal.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: width * 2, dy: height * 20.5)).doubleTap()
        waitForDiagnosticMetrics(in: app) { $0["nativeSelectionLength"] == 6 }
        let rowY = try requiredDiagnosticMetric("nativeSelectionY", in: app)
        app.buttons["vvterm.keyboardTest.selection.output"].tap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionEndHandleY"] ?? -1) >= 0 }
        let handleX = try requiredDiagnosticMetric("nativeSelectionEndHandleX", in: app)
        let handleY = try requiredDiagnosticMetric("nativeSelectionEndHandleY", in: app)
        let handle = origin.withOffset(CGVector(dx: handleX, dy: handleY))
        let target = origin.withOffset(CGVector(dx: handleX + width * 7, dy: handleY))
        handle.press(forDuration: 0.5, thenDragTo: target)
        waitForDiagnosticMetrics(in: app) {
            ($0["nativeSelectionLength"] ?? 0) > 6 && ($0["nativeSelectionLength"] ?? 0) < 35
        }
        let text = try selectionText(in: app)
        XCTAssertTrue(text.hasPrefix("56565465726d20"), text) // "VVTerm "
        waitForDiagnosticMetrics(in: app, timeout: 15) { $0["selectionOutputRows"] == 80 }
        XCTAssertEqual(try selectionText(in: app), text)
        XCTAssertEqual(try requiredDiagnosticMetric("nativeSelectionY", in: app), rowY)
    }

    @MainActor
    func testErasedTextClearsSelection() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        let cellHeight = try requiredDiagnosticMetric("linkCellHeight", in: app)
        terminal.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 20, dy: cellHeight * 20.5)).doubleTap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        app.buttons["vvterm.keyboardTest.selection.erase"].tap()
        waitForDiagnosticMetrics(in: app) { $0["nativeSelectionLength"] == 0 }
        XCTAssertTrue(diagnosticsText(in: app).contains("nativeSelectionTextHex=none"))
    }

    @MainActor
    private func selectionText(in app: XCUIApplication) throws -> String {
        let token = diagnosticsText(in: app).split(separator: " ")
            .first { $0.hasPrefix("nativeSelectionTextHex=") }
        let value = try XCTUnwrap(token?.split(separator: "=", maxSplits: 1).last)
        XCTAssertFalse(value.isEmpty)
        XCTAssertNotEqual(value, "none")
        return String(value)
    }
}
#endif
