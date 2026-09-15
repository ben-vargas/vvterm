#if os(iOS)
import XCTest
import UIKit

final class TerminalSelectionStabilityUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testSelectionHandlesRemainDrawn() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        let height = try requiredDiagnosticMetric("linkCellHeight", in: app)
        terminal.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 20, dy: height * 20.5)).doubleTap()
        waitForDiagnosticMetrics(in: app) {
            ($0["nativeSelectionStartHandleY"] ?? -1) >= 0 && ($0["nativeSelectionEndHandleY"] ?? -1) >= 0
        }
        let capture = app.screenshot()
        let screenshot = XCTAttachment(screenshot: capture)
        screenshot.name = "Visible selection pins"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let image = try XCTUnwrap(capture.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        for endpoint in ["Start", "End"] {
            let x = try requiredDiagnosticMetric("nativeSelection\(endpoint)HandleX", in: app)
            let y = try requiredDiagnosticMetric("nativeSelection\(endpoint)HandleY", in: app)
            let area = CGRect(x: (terminal.frame.minX + x - 14) * scale,
                              y: (terminal.frame.minY + y - 14) * scale,
                              width: 28 * scale, height: 28 * scale)
            let pin = try XCTUnwrap(image.cropping(to: area))
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            try pixels.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 64, height: 64,
                    bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pin, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            // Native blue pins are brighter than the terminal selection highlight.
            let bluePixels = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] < 100 && pixels[$0 + 1] < 180 && pixels[$0 + 2] > 190
            }.count
            XCTAssertGreaterThan(bluePixels, 10, "\(endpoint) pin is not drawn")
        }
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
    func testBothHandlesExtendSelectionWithImmediateDrags() throws {
        try assertRepeatedHandleDrags(initialDrag: false)
    }

    @MainActor
    func testBothHandlesExtendSelectionAfterInitialDrag() throws {
        try assertRepeatedHandleDrags(initialDrag: true)
    }

    @MainActor
    func testBothHandlesExtendSelectionDuringTUIRedraws() throws {
        try assertRepeatedHandleDrags(initialDrag: true, redraws: true)
    }

    @MainActor
    private func assertRepeatedHandleDrags(initialDrag: Bool, redraws: Bool = false) throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, seedsTerminalSelectionFixture: true, simulatesSelectionRedraws: redraws)
        let terminal = waitForTerminal(in: app)
        let height = try requiredDiagnosticMetric("linkCellHeight", in: app)
        let width = try requiredDiagnosticMetric("selectionCellWidth", in: app)
        let origin = terminal.coordinate(withNormalizedOffset: .zero)
        let initial = origin.withOffset(CGVector(dx: width * 9, dy: height * 20.5))
        if initialDrag {
            initial.press(forDuration: 0.3, thenDragTo: origin.withOffset(CGVector(dx: width * 20, dy: height * 20.5)))
        } else {
            initial.doubleTap()
        }
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }

        let initialRedraws = try requiredDiagnosticMetric("selectionRedraws", in: app)
        for endpoint in ["End", "Start", "End"] {
            let length = try requiredDiagnosticMetric("nativeSelectionLength", in: app)
            let x = try requiredDiagnosticMetric("nativeSelection\(endpoint)HandleX", in: app)
            let y = try requiredDiagnosticMetric("nativeSelection\(endpoint)HandleY", in: app)
            XCTAssertGreaterThanOrEqual(x, 0)
            XCTAssertGreaterThanOrEqual(y, 0)
            let direction: CGFloat = endpoint == "Start" ? -1 : 1
            let handle = origin.withOffset(CGVector(dx: x, dy: y))
            let target = origin.withOffset(CGVector(dx: x + width * 5 * direction, dy: y))
            handle.press(forDuration: 0.05, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0)
            waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > length }
        }
        if redraws {
            let text = try selectionText(in: app)
            let frames = try requiredDiagnosticMetric("selectionRedraws", in: app)
            XCTAssertGreaterThan(frames, initialRedraws)
            waitForDiagnosticMetrics(in: app) { ($0["selectionRedraws"] ?? 0) > frames + 5 }
            XCTAssertEqual(try selectionText(in: app), text)
        }
    }

    @MainActor
    func testBottomHandleSurvivesSelectedFooterAnimation() throws {
        let app = launchKeyboardHarness(seedsTerminalSelectionFixture: true, simulatesSelectionBottomRedraws: true)
        waitForDiagnosticMetrics(in: app) { ($0["keyboardHeight"] ?? 0) > 0 }
        let terminal = waitForTerminal(in: app)
        let height = try requiredDiagnosticMetric("linkCellHeight", in: app)
        let width = try requiredDiagnosticMetric("selectionCellWidth", in: app)
        let rows = try requiredDiagnosticMetric("gridRows", in: app)
        let origin = terminal.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: width * 2, dy: height * (rows - 2.5))).doubleTap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        XCTAssertEqual(try selectionText(in: app), "73656c6563746564") // "selected"
        let x = try requiredDiagnosticMetric("nativeSelectionEndHandleX", in: app)
        let y = try requiredDiagnosticMetric("nativeSelectionEndHandleY", in: app)
        origin.withOffset(CGVector(dx: x, dy: y)).press(
            forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: width * 20, dy: height * (rows - 1.5))),
            withVelocity: .slow, thenHoldForDuration: 0.3
        )
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 25 }
        let length = try requiredDiagnosticMetric("nativeSelectionLength", in: app)
        let startY = try requiredDiagnosticMetric("nativeSelectionY", in: app)
        let frames = try requiredDiagnosticMetric("selectionRedraws", in: app)
        waitForDiagnosticMetrics(in: app) { ($0["selectionRedraws"] ?? 0) > frames + 10 }
        XCTAssertEqual(try requiredDiagnosticMetric("nativeSelectionLength", in: app), length)
        XCTAssertEqual(try requiredDiagnosticMetric("nativeSelectionY", in: app), startY)
    }

    @MainActor
    func testBottomSelectionSurvivesSuggestionBarHeightChanges() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        app.buttons["vvterm.keyboardTest.selection.bottom"].tap()
        let height = try requiredDiagnosticMetric("linkCellHeight", in: app)
        let width = try requiredDiagnosticMetric("selectionCellWidth", in: app)
        let rows = try requiredDiagnosticMetric("gridRows", in: app)
        let origin = terminal.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: width * 2, dy: height * (rows - 1.5))).doubleTap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        let selected = try selectionText(in: app)
        XCTAssertEqual(selected, "626f74746f6d") // "bottom"
        for _ in 0..<3 {
            app.buttons["vvterm.keyboardTest.geometry.suggestions"].tap()
            waitForDiagnosticMetrics(in: app) { ($0["gridRows"] ?? rows) < rows }
            XCTAssertEqual(try selectionText(in: app), selected)
            app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
            waitForDiagnosticMetrics(in: app) { $0["gridRows"] == rows }
            XCTAssertEqual(try selectionText(in: app), selected)
        }
        let x = try requiredDiagnosticMetric("nativeSelectionEndHandleX", in: app)
        let y = try requiredDiagnosticMetric("nativeSelectionEndHandleY", in: app)
        origin.withOffset(CGVector(dx: x, dy: y)).press(
            forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: x + width * 5, dy: y)),
            withVelocity: .slow, thenHoldForDuration: 0
        )
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 6 }
    }

    @MainActor
    func testHandleAutoscrollExtendsSelectionAndStopsOnRelease() throws {
        try assertSelectionAutoscroll(longPress: false)
    }

    @MainActor
    func testLongPressAutoscrollExtendsSelectionAndStopsOnRelease() throws {
        try assertSelectionAutoscroll(longPress: true)
    }

    @MainActor
    private func assertSelectionAutoscroll(longPress: Bool) throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, simulatesTerminalMouseCapture: true, seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        app.buttons["vvterm.keyboardTest.selection.output"].tap()
        waitForDiagnosticMetrics(in: app, timeout: 15) { $0["selectionOutputRows"] == 80 }
        let height = try requiredDiagnosticMetric("linkCellHeight", in: app)
        let width = try requiredDiagnosticMetric("selectionCellWidth", in: app)
        let rows = try requiredDiagnosticMetric("gridRows", in: app)
        let origin = terminal.coordinate(withNormalizedOffset: .zero)
        let initial = origin.withOffset(CGVector(dx: width * 2, dy: height * 10.5))
        let dragStart: XCUICoordinate
        if longPress {
            dragStart = initial
        } else {
            initial.doubleTap()
            waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
            let x = try requiredDiagnosticMetric("nativeSelectionStartHandleX", in: app)
            let y = try requiredDiagnosticMetric("nativeSelectionStartHandleY", in: app)
            dragStart = origin.withOffset(CGVector(dx: x, dy: y))
        }
        dragStart.press(
            forDuration: longPress ? 0.5 : 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: width * 2, dy: 1)),
            withVelocity: .slow, thenHoldForDuration: 4
        )
        let selected = try selectionText(in: app)
        // More selected text than one viewport proves the fixed end survived offscreen.
        XCTAssertGreaterThan(Double(selected.components(separatedBy: "0a").count), rows)
        // The real end is below the viewport. No handle belongs at its clipped edge.
        XCTAssertEqual(try requiredDiagnosticMetric("nativeSelectionEndHandleY", in: app), -1, diagnosticsText(in: app))
        waitForDiagnosticMetrics(in: app) { $0["selectionAutoscrolling"] == 0 }
        XCTAssertEqual(try selectionText(in: app), selected)
        XCTAssertEqual(try requiredDiagnosticMetric("mouseScrollReports", in: app), 0)
        // The selection menu can consume the first outside tap to dismiss itself.
        let latest = app.buttons["vvterm.keyboardTest.selection.latest"]
        latest.tap()
        latest.tap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionEndHandleY"] ?? -1) >= 0 }
        XCTAssertEqual(try selectionText(in: app), selected)
        XCTAssertEqual(try requiredDiagnosticMetric("nativeSelectionEndHandleY", in: app), height * 10.5, accuracy: 1)
    }

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
    func testTerminalResetClearsSelection() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true, seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        let cellHeight = try requiredDiagnosticMetric("linkCellHeight", in: app)
        terminal.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 20, dy: cellHeight * 20.5)).doubleTap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        app.buttons["vvterm.keyboardTest.selection.reset"].tap()
        waitForDiagnosticMetrics(in: app) { $0["nativeSelectionLength"] == 0 }
        XCTAssertTrue(diagnosticsText(in: app).contains("nativeSelectionTextHex=none"))
    }

    @MainActor
    private func selectionText(in app: XCUIApplication) throws -> String {
        let token = diagnosticsText(in: app).split(separator: " ")
            .first { $0.hasPrefix("nativeSelectionTextHex=") }
        let value = try XCTUnwrap(token?.split(separator: "=", maxSplits: 1).last)
        XCTAssertFalse(value.isEmpty)
        XCTAssertNotEqual(value, "none", diagnosticsText(in: app))
        return String(value)
    }
}
#endif
