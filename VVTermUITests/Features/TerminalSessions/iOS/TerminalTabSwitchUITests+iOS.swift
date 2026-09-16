#if os(iOS)
import XCTest

/// Requires the loopback SSH credentials used by TerminalReconnectUITestHarness.
/// Its interactive PTY fixture must set the OSC 0 title to `INPUT_<line>` after
/// each submitted line; that response verifies input reached the selected shell.
final class TerminalTabSwitchUITests: TerminalReconnectUITestCase {
    @MainActor
    func testTabStripAlignsWithToolbar() throws {
        let (app, _) = launchProductionSSHTestHarness(tabSwitching: true)
        defer { app.terminate() }

        let tabs = app.otherElements["vvterm.terminal.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        let navigationBar = app.navigationBars.firstMatch
        let back = navigationBar.otherElements["vvterm.terminal.back"]
        let menu = navigationBar.otherElements["vvterm.terminal.moreMenu"]
        // Native glass extends four points outside the toolbar content's
        // accessibility frame. Compare the visible outer edges.
        if #available(iOS 26, *) {
            XCTAssertEqual(tabs.frame.minX, back.frame.minX - 4, accuracy: 1)
            XCTAssertEqual(tabs.frame.maxX, menu.frame.maxX + 4, accuracy: 1)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Terminal tabs aligned with toolbar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNormalTabsPreserveKeyboardGridAndInputRouting() throws {
        try checkTabSwitches(chat: false)
    }

    @MainActor
    func testNormalTabSwitchKeepsTerminalAboveKeyboard() throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(tabSwitching: true)
        defer { app.terminate() }
        let tabs = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "vvterm.terminal.tab."
        ))
        XCTAssertEqual(tabs.count, 2)
        let keyboard = app.keyboards.firstMatch
        if diagnosticValue("keyboardVisible", in: diagnostics) != "true" {
            openProductionTerminalMenu(in: app)
            app.buttons["vvterm.terminal.inputMenu"].tap()
            app.buttons["vvterm.terminal.input.keyboard"].tap()
            wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))

        for index in [1, 0, 1, 0] {
            tabs.element(boundBy: index).tap()
            wait(for: diagnostics, containing: "state=connected", timeout: 20, app: app)
            XCTAssertTrue(keyboard.exists, diagnosticText(in: app))
            XCTAssertEqual(diagnosticValue("keyboardVisible", in: diagnostics), "true")
            let terminal = productionTerminal(in: app)
            XCTAssertLessThanOrEqual(
                terminal.frame.maxY,
                keyboard.frame.minY + 2,
                "The selected terminal extends under the visible keyboard. \(diagnosticText(in: app))"
            )
        }
    }

    @MainActor
    func testChatTabsPreserveKeyboardGridAndDrafts() throws {
        try checkTabSwitches(chat: true)
    }

    @MainActor
    private func checkTabSwitches(chat: Bool) throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(tabSwitching: true, chatMode: chat)
        defer { app.terminate() }
        let tabs = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "vvterm.terminal.tab."
        ))
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(diagnosticIntegerValue("tabAttached", in: diagnostics), 1)
        for index in [1, 0] {
            tabs.element(boundBy: index).tap()
            XCTAssertTrue(tabs.element(boundBy: index).isSelected)
            wait(for: diagnostics, containing: "state=connected", timeout: 20, app: app)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
            sleep(2)
            // Establish a visible software keyboard before measuring continuity.
            if diagnosticValue("keyboardVisible", in: diagnostics) != "true" {
                openProductionTerminalMenu(in: app)
                app.buttons["vvterm.terminal.inputMenu"].tap()
                app.buttons["vvterm.terminal.input.keyboard"].tap()
                wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
            }
        }
        wait(for: diagnostics, containing: "tabAttached=2", timeout: 5, app: app)
        let hides = try XCTUnwrap(diagnosticIntegerValue("keyboardHides", in: diagnostics))
        let resizes = try XCTUnwrap(diagnosticIntegerValue("tabResizes", in: diagnostics))
        var snapshots: [Int: TerminalSnapshot] = [:]
        var grids: [Int: String] = [:]
        var titles: [Int: String] = [:]
        for (step, index) in [0, 1, 0, 1, 0, 1].enumerated() {
            tabs.element(boundBy: index).tap()
            XCTAssertTrue(tabs.element(boundBy: index).isSelected)
            sleep(1)
            XCTAssertTrue(app.keyboards.firstMatch.exists, diagnosticText(in: app))
            XCTAssertEqual(diagnosticValue("keyboardVisible", in: diagnostics), "true")
            XCTAssertEqual(diagnosticIntegerValue("keyboardHides", in: diagnostics), hides)
            XCTAssertEqual(diagnosticIntegerValue("tabResizes", in: diagnostics), resizes)
            XCTAssertEqual(diagnosticIntegerValue("tabAttached", in: diagnostics), 2)
            XCTAssertEqual(diagnosticIntegerValue("tabPaused", in: diagnostics), 1)
            let grid = "\(diagnosticIntegerValue("gridCols", in: diagnostics) ?? 0)x\(diagnosticIntegerValue("gridRows", in: diagnostics) ?? 0)"
            if let prior = snapshots[index] { assertSameSession(as: prior, diagnostics: diagnostics, app: app) }
            else { snapshots[index] = try terminalSnapshot(in: diagnostics, app: app); grids[index] = grid }
            XCTAssertEqual(grid, grids[index])
            if chat {
                let expected = index == 0 ? "first" : "second"
                if step < 2 {
                    for character in expected { app.keys[String(character)].tap() }
                }
                wait(for: diagnostics, containing: "draft=\(expected)|", timeout: 5, app: app)
            } else {
                if let title = titles[index] { wait(for: diagnostics, containing: title, timeout: 5, app: app) }
                let text = String(repeating: index == 0 ? "a" : "b", count: step + 1)
                for character in text { app.keys[String(character)].tap() }
                app.buttons["Return"].firstMatch.tap()
                let title = "title=INPUT_\(text)"
                wait(for: diagnostics, containing: title, timeout: 5, app: app)
                titles[index] = title
            }
        }
    }
}
#endif
