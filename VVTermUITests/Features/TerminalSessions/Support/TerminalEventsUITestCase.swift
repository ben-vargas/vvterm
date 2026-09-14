import XCTest
import CoreGraphics
import ImageIO

@MainActor
class TerminalEventsUITestCase: XCTestCase {
    func verifyNotificationSettingsSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["--vvterm-ui-test-notification-settings", "--vvterm-ui-testing",
                               "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO"]
        app.launch()
        defer { app.terminate() }
        let toggle = app.switches["vvterm.settings.notifications"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        // macOS returns NSNumber; iOS returns String for the native switch value.
        expectation(for: NSPredicate { _, _ in
            String(describing: toggle.value ?? "") == "1"
        }, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        #if os(iOS)
        // Accessibility includes the whole row; tap the trailing native control.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -35, dy: 0)).tap()
        #else
        toggle.click()
        #endif
        XCTAssertEqual(String(describing: toggle.value ?? ""), "0")
        #if os(iOS)
        // Accessibility includes the whole row; tap the trailing native control.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -35, dy: 0)).tap()
        #else
        toggle.click()
        #endif
        XCTAssertEqual(String(describing: toggle.value ?? ""), "1")
        attach(app, name: "notification-settings-switch")
    }

    func verifyPaneProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-events", "--vvterm-ui-testing",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.fullAppLockEnabled", "NO", "-security.privacyModeEnabled", "NO"
        ]
        continueAfterFailure = false
        app.launch()
        app.activate()
        defer { app.terminate() }
        let half = app.buttons["events.half"]
        XCTAssertTrue(half.waitForExistence(timeout: 15))
        let bars = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "vvterm.terminal.progress."
        ))
        XCTAssertEqual(bars.count, 0)
        press(half)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Terminal event accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        waitForCount(1, elements: bars)
        let first = bars.element(boundBy: 0)
        let firstID = first.identifier
        #if os(macOS)
        XCTAssertEqual((first.value as? NSNumber)?.doubleValue, 0.5)
        #else
        XCTAssertEqual(first.value as? String, "50 percent complete")
        #endif
        let firstPane = app.descendants(matching: .any)["events.pane.0"]
        let paneFrame = firstPane.frame
        XCTAssertEqual(first.frame.width, paneFrame.width / 2, accuracy: 1)
        XCTAssertEqual(first.frame.minY, paneFrame.minY, accuracy: 1)
        XCTAssertEqual(first.frame.height, 2, accuracy: 1)
        let originalFrame = first.frame
        let initialDiagnostics = diagnosticText(app.staticTexts["events.diagnostics"])
        attach(app, name: "half-progress")

        press(app.buttons["events.pause"])
        waitForLabel("Terminal progress - Paused", element: first)
        attach(app, name: "paused-progress")
        press(app.buttons["events.error"])
        waitForLabel("Terminal progress - Error", element: first)
        attach(app, name: "error-progress")
        press(app.buttons["events.busy"])
        let busy = NSPredicate(format: "label == %@", "Operation in progress")
        expectation(for: busy, evaluatedWith: first)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(first.frame.minX, originalFrame.minX, accuracy: 1)
        XCTAssertEqual(first.frame.minY, originalFrame.minY, accuracy: 1)
        XCTAssertEqual(first.frame.height, originalFrame.height, accuracy: 1)
        XCTAssertEqual(firstPane.frame, paneFrame)
        XCTAssertEqual(diagnosticText(app.staticTexts["events.diagnostics"]), initialDiagnostics)
        attach(app, name: "indeterminate-progress")

        selectPane("B", app: app)
        press(half)
        waitForCount(2, elements: bars)
        XCTAssertTrue(app.descendants(matching: .any)[firstID].exists)
        press(app.buttons["events.remove"])
        waitForCount(1, elements: bars)
        XCTAssertEqual(bars.element(boundBy: 0).identifier, firstID)
        selectPane("A", app: app)
        press(app.buttons["events.replace"])
        waitForCount(0, elements: bars)
        press(half)
        waitForCount(1, elements: bars)

        press(app.buttons["events.notify"])
        let diagnostics = app.staticTexts["events.diagnostics"]
        expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "notifications=1 Test: Ready", "notifications=1 Test: Ready"), evaluatedWith: diagnostics)
        waitForExpectations(timeout: 5)
        // Permission is denied in the test client; OSC handling must still leave
        // the terminal and progress path operational.
        press(app.buttons["events.remove"])
        waitForCount(0, elements: bars)
        press(half)
        waitForCount(1, elements: bars)
        waitForCount(0, elements: bars, timeout: 18)
    }

    func verifyBusyProgressMoves() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-events", "--vvterm-ui-testing",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.fullAppLockEnabled", "NO", "-security.privacyModeEnabled", "NO"
        ]
        continueAfterFailure = false
        app.launch()
        app.activate()
        defer { app.terminate() }
        let busy = app.buttons["events.busy"]
        XCTAssertTrue(busy.waitForExistence(timeout: 15))
        // Starting with state 3 must animate without an earlier determinate report.
        press(busy)
        let pane = app.descendants(matching: .any)["events.pane.0"]
        try verifyBusyMovement(in: pane)
        // The manual script enters busy mode after determinate, pause, and error.
        press(app.buttons["events.half"])
        press(app.buttons["events.pause"])
        press(app.buttons["events.error"])
        press(busy)
        try verifyBusyMovement(in: pane)
    }

    func verifyNotificationOpensSourcePane(sourceClosed: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-events", "--vvterm-ui-testing",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.fullAppLockEnabled", "NO", "-security.privacyModeEnabled", "NO"
        ]
        continueAfterFailure = false
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["events.notify"].waitForExistence(timeout: 15))
        selectPane("B", app: app)
        press(app.buttons["events.notify"])
        let diagnostics = app.staticTexts["events.diagnostics"]
        expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "notifications=1", "notifications=1"), evaluatedWith: diagnostics)
        waitForExpectations(timeout: 5)
        selectPane("A", app: app)
        press(app.buttons["events.other-tab"])
        XCTAssertTrue(app.staticTexts["events.other-tab-content"].waitForExistence(timeout: 5))
        if sourceClosed { press(app.buttons["events.close-source"]) }
        press(app.buttons["events.open-notification"])
        let destination = app.staticTexts["events.notification-destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        if sourceClosed {
            XCTAssertEqual(diagnosticText(destination), "App")
            XCTAssertTrue(app.staticTexts["events.other-tab-content"].exists)
            return
        }
        XCTAssertEqual(diagnosticText(destination), "Source tab, pane B")
        XCTAssertTrue(app.descendants(matching: .any)["events.pane.1"].exists)
        XCTAssertFalse(app.staticTexts["events.other-tab-content"].exists)
        // Produce fresh terminal output after remounting the real pane host.
        // Routing alone is insufficient if the retained view was left paused.
        press(app.buttons["events.busy"])
        #if os(iOS)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "B=ready"), evaluatedWith: diagnostics)
        waitForExpectations(timeout: 3)
        #endif
        attach(app, name: "notification-opened-source-pane")
    }

    private func verifyBusyMovement(in pane: XCUIElement) throws {
        var positions: [Double] = []
        for index in 0..<12 {
            let screenshot = pane.screenshot()
            positions.append(try busySegmentPosition(screenshot, paneWidth: pane.frame.width))
            if index == 0 || index == 6 {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "busy-motion-\(index)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let changes = zip(positions, positions.dropFirst()).map { $1 - $0 }
        XCTAssertGreaterThan((positions.max() ?? 0) - (positions.min() ?? 0), 0.4, "Positions: \(positions)")
        XCTAssertTrue(changes.contains { $0 > 0.05 }, "Must move right: \(positions)")
        XCTAssertTrue(changes.contains { $0 < -0.05 }, "Must move left: \(positions)")
    }

    private func busySegmentPosition(_ screenshot: XCUIScreenshot, paneWidth: CGFloat) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = max(1, Int(2 * CGFloat(width) / paneWidth))
        let strip = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var columns: [Int] = []
        for x in 0..<width {
            if (0..<height).contains(where: { y in
                let offset = (y * width + x) * 4
                let colors = pixels[offset..<(offset + 3)]
                let high = Int(colors.max() ?? 0)
                let low = Int(colors.min() ?? 0)
                return high > 140 && high - low > 60
            }) { columns.append(x) }
        }
        XCTAssertFalse(columns.isEmpty, "The bright busy segment must be visible")
        return Double(columns.reduce(0, +)) / Double(max(1, columns.count)) / Double(width)
    }

    private func diagnosticText(_ element: XCUIElement) -> String {
        #if os(macOS)
        return element.value as? String ?? element.label
        #else
        return element.label
        #endif
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func selectPane(_ name: String, app: XCUIApplication) {
        #if os(macOS)
        app.radioButtons[name].click()
        #else
        app.buttons[name].tap()
        #endif
    }

    private func waitForCount(_ count: Int, elements: XCUIElementQuery, timeout: TimeInterval = 5) {
        expectation(for: NSPredicate { _, _ in elements.count == count }, evaluatedWith: nil)
        waitForExpectations(timeout: timeout)
    }

    private func waitForLabel(_ label: String, element: XCUIElement) {
        expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
