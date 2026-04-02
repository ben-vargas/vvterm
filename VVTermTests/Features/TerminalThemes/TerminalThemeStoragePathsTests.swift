import XCTest
@testable import VVTerm

final class TerminalThemeStoragePathsTests: XCTestCase {
    func testCustomThemeFilePathEndsWithThemeName() {
        let path = TerminalThemeStoragePaths.customThemeFilePath(for: "MyTheme")

        XCTAssertTrue(path.hasSuffix("/CustomThemes/MyTheme") || path.hasSuffix("\\CustomThemes\\MyTheme"))
    }
}
