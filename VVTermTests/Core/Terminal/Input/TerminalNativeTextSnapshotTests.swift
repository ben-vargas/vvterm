#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalNativeTextSnapshotTests {
    @Test
    func staleUIKitRangeCannotSelectTextInANewSnapshot() {
        let first = TerminalNativeTextSnapshot(lines: ["before"], cellSize: .init(width: 10, height: 20), columns: 20)
        let range = first.nativeRange(NSRange(location: 0, length: 3))
        let next = TerminalNativeTextSnapshot(lines: ["after"], cellSize: first.cellSize, columns: 20)
        #expect(first.nativeRange(from: range) == NSRange(location: 0, length: 3))
        #expect(next.nativeRange(from: range) == nil)
        #expect(next.offset(for: CGPoint(x: CGFloat.infinity, y: CGFloat.nan)) == 0)
    }

    @Test
    func wideAndCombinedCharactersUseTerminalCellGeometry() {
        let snapshot = TerminalNativeTextSnapshot(
            lines: ["A😀界e\u{301}Z"], cellSize: CGSize(width: 10, height: 20), columns: 20,
            cells: [
                .init(range: NSRange(location: 0, length: 1), row: 0, column: 0, width: 1),
                .init(range: NSRange(location: 1, length: 2), row: 0, column: 1, width: 2),
                .init(range: NSRange(location: 3, length: 1), row: 0, column: 3, width: 2),
                .init(range: NSRange(location: 4, length: 2), row: 0, column: 5, width: 1),
                .init(range: NSRange(location: 6, length: 1), row: 0, column: 6, width: 1)
            ]
        )
        #expect(snapshot.characterRange(at: CGPoint(x: 25, y: 5)) == NSRange(location: 1, length: 2))
        #expect(snapshot.characterRange(at: CGPoint(x: 45, y: 5)) == NSRange(location: 3, length: 1))
        #expect(snapshot.caretRect(for: 4).minX == 50)
        #expect(snapshot.caretRect(for: 6).minX == 60)
        let rects = snapshot.selectionRects(for: NSRange(location: 1, length: 3))
        #expect(rects.count == 1)
        #expect(rects.first?.rect == CGRect(x: 10, y: 0, width: 40, height: 20))
    }
}
#endif
