import XCTest
@testable import VVTerm

final class TerminalThemeValidationTests: XCTestCase {
    func testNormalizeHexColorUppercasesAndPrefixesHash() {
        XCTAssertEqual(TerminalThemeValidator.normalizeHexColor("aabbcc"), "#AABBCC")
        XCTAssertEqual(TerminalThemeValidator.normalizeHexColor("#aabbcc"), "#AABBCC")
    }

    func testValidateAndNormalizeThemeContentRequiresBackgroundAndForeground() throws {
        let content = """
        background = #000000
        foreground = #ffffff
        palette = 0=#112233
        """

        let normalized = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)

        XCTAssertEqual(
            normalized,
            """
            background = #000000
            foreground = #FFFFFF
            palette = 0=#112233
            """
            + "\n"
        )
    }

    func testValidateAndNormalizeThemeContentRejectsInvalidPalette() {
        let content = """
        background = #000000
        foreground = #ffffff
        palette = 20=#112233
        """

        XCTAssertThrowsError(try TerminalThemeValidator.validateAndNormalizeThemeContent(content))
    }
}
