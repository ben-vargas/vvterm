#if os(macOS)
import XCTest

final class TerminalEventsUITests: TerminalEventsUITestCase {
    @MainActor
    func testNotificationSettingsSwitch() { verifyNotificationSettingsSwitch() }

    @MainActor
    func testClosedNotificationOpensApp() throws { try verifyNotificationOpensSourcePane(sourceClosed: true) }

    @MainActor
    func testNotificationOpensSourceTabAndPane() throws { try verifyNotificationOpensSourcePane() }

    @MainActor
    func testBusyProgressMovesBothDirections() throws { try verifyBusyProgressMoves() }

    @MainActor
    func testRealOSCEventsInSplitPanes() throws { try verifyPaneProgress() }
}
#endif
