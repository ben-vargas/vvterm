#if os(iOS)
import XCTest

final class TerminalKeyboardInputModeUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testInputModeChangeKeepsCurrentKeyboardSession() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        let reloadCount = try requiredDiagnosticMetric("inputReloads", in: app)
        let inputModeButton = app.buttons["vvterm.keyboardTest.inputMode.changed"]
        XCTAssertTrue(
            inputModeButton.waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )

        inputModeButton.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        XCTAssertEqual(
            try requiredDiagnosticMetric("inputReloads", in: app),
            reloadCount,
            "Input mode selection reloaded the active keyboard. \(diagnosticsText(in: app))"
        )
        assertKeyboardSessionAndAccessoryVisible(in: app)
    }
}
#endif
