import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import VVTerm

final class ConnectionViewTabPresentationTests: XCTestCase {
    func testTabPresentationPreservesLocalizedKeysAndSymbols() {
        XCTAssertEqual(ConnectionViewTabID.stats.localizedKey, "Stats")
        XCTAssertEqual(ConnectionViewTabID.stats.icon, "chart.bar.xaxis")
        XCTAssertEqual(ConnectionViewTabID.terminal.localizedKey, "Terminal")
        XCTAssertEqual(ConnectionViewTabID.terminal.icon, "terminal")
        XCTAssertEqual(ConnectionViewTabID.files.localizedKey, "Files")
        XCTAssertEqual(ConnectionViewTabID.files.icon, "folder")
    }

    #if os(macOS)
    @MainActor
    func testBackgroundFollowsTheSurfaceInsteadOfTheTerminalTheme() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for terminalBackground in [Color.red, Color.blue] {
                    for tab in ConnectionViewTabID.allCases {
                        let expected = tab == .terminal
                            ? terminalBackground
                            : Color(nsColor: .windowBackgroundColor)
                        XCTAssertEqual(
                            tab.backgroundColor(terminalBackground: terminalBackground),
                            expected,
                            "Unexpected background for \(tab) in \(name)"
                        )
                    }
                }
            }
        }
    }
    #endif

}
