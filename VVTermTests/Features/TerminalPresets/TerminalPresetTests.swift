import XCTest
@testable import VVTerm

final class TerminalPresetTests: XCTestCase {
    func testDefaultTerminalIsBuiltInAndUsesTerminalIcon() {
        XCTAssertTrue(TerminalPreset.defaultTerminal.isBuiltIn)
        XCTAssertEqual(TerminalPreset.defaultTerminal.name, "Terminal")
        XCTAssertEqual(TerminalPreset.defaultTerminal.icon, "terminal")
        XCTAssertEqual(TerminalPreset.defaultTerminal.command, "")
    }
}
