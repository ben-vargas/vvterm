#if os(iOS)
import XCTest

final class TerminalContentPaddingUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testMaximumPaddingUpdatesBothActiveSplitPanesAndKeepsValidGrids() throws {
        let app = launchKeyboardHarness(splitPaneFocus: true)
        defer { app.terminate() }

        let firstSurface = app.descendants(matching: .any)[
            "vvterm.keyboardTest.terminalSurface.first"
        ]
        let secondSurface = app.descendants(matching: .any)[
            "vvterm.keyboardTest.terminalSurface.second"
        ]
        XCTAssertTrue(firstSurface.waitForExistence(timeout: 10), diagnosticsText(in: app))
        XCTAssertTrue(secondSurface.waitForExistence(timeout: 10), diagnosticsText(in: app))

        let initialFirstColumns = try requiredDiagnosticMetric("firstGridCols", in: app)
        let initialFirstRows = try requiredDiagnosticMetric("firstGridRows", in: app)
        let initialSecondColumns = try requiredDiagnosticMetric("secondGridCols", in: app)
        let initialSecondRows = try requiredDiagnosticMetric("secondGridRows", in: app)

        app.buttons["vvterm.keyboardTest.padding.maximum"].tap()
        waitForDiagnosticMetrics(in: app) { metrics in
            metrics["paddingX"] == 32
                && metrics["paddingY"] == 32
                && (metrics["firstGridCols"] ?? 0) > 0
                && (metrics["firstGridRows"] ?? 0) > 0
                && (metrics["secondGridCols"] ?? 0) > 0
                && (metrics["secondGridRows"] ?? 0) > 0
                && (metrics["firstGridCols"] ?? initialFirstColumns) < initialFirstColumns
                && (metrics["firstGridRows"] ?? initialFirstRows) < initialFirstRows
                && (metrics["secondGridCols"] ?? initialSecondColumns) < initialSecondColumns
                && (metrics["secondGridRows"] ?? initialSecondRows) < initialSecondRows
        }

        XCTAssertTrue(firstSurface.exists, diagnosticsText(in: app))
        XCTAssertTrue(secondSurface.exists, diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.padding.zero"].tap()
        waitForDiagnosticMetrics(in: app) { metrics in
            metrics["paddingX"] == 0
                && metrics["paddingY"] == 0
                && metrics["firstGridCols"] == initialFirstColumns
                && metrics["firstGridRows"] == initialFirstRows
                && metrics["secondGridCols"] == initialSecondColumns
                && metrics["secondGridRows"] == initialSecondRows
        }
    }
}
#endif
