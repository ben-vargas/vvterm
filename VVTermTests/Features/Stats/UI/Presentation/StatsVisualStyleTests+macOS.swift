#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import VVTerm

@MainActor
final class StatsVisualStyleTests: XCTestCase {
    func testLightDashboardCardsRemainDistinctOnWhitePages() throws {
        for preference in [StatsPreferences.Style.cardsCompact, .cardsDetailed] {
            let style = StatsVisualStyle(preferencesStyle: preference, colorScheme: .light)
            let content = Rectangle()
                .fill(style.cardFill)
                .frame(width: 40, height: 40)
                .frame(width: 100, height: 60)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let page = try XCTUnwrap(bitmap.colorAt(x: 5, y: 30)?.usingColorSpace(.deviceRGB))
            let card = try XCTUnwrap(bitmap.colorAt(x: 50, y: 30)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(page.redComponent - card.redComponent, 0.025)
            XCTAssertGreaterThan(page.greenComponent - card.greenComponent, 0.025)
            XCTAssertGreaterThan(page.blueComponent - card.blueComponent, 0.025)
        }
    }
}
#endif
