import Foundation
import Testing
@testable import VVTerm

struct TerminalSelectionHandleTests {
    @Test func movesEitherEndWithoutMovingTheOther() {
        let range = NSRange(location: 10, length: 10)
        #expect(TerminalSelectionHandle.start.moving(to: 3, in: range)?.range == NSRange(location: 3, length: 17))
        #expect(TerminalSelectionHandle.end.moving(to: 30, in: range)?.range == NSRange(location: 10, length: 20))
        #expect(TerminalSelectionHandle.start.moving(to: 15, in: range)?.range == NSRange(location: 15, length: 5))
        #expect(TerminalSelectionHandle.end.moving(to: 15, in: range)?.range == NSRange(location: 10, length: 5))
    }

    @Test func crossingKeepsTheSameFixedEnd() {
        let range = NSRange(location: 10, length: 10)
        let crossed = TerminalSelectionHandle.start.moving(to: 25, in: range)
        #expect(crossed?.handle == .end)
        #expect(crossed?.range == NSRange(location: 20, length: 5))
        #expect(crossed?.handle.moving(to: 30, in: crossed!.range)?.range == NSRange(location: 20, length: 10))
        #expect(TerminalSelectionHandle.end.moving(to: 5, in: range)?.handle == .start)
        #expect(TerminalSelectionHandle.start.moving(to: 20, in: range) == nil)
    }

    @Test func rejectsInvalidRanges() {
        #expect(TerminalSelectionHandle.start.moving(to: -1, in: NSRange(location: 1, length: 2)) == nil)
        #expect(TerminalSelectionHandle.end.moving(to: 1, in: NSRange(location: Int.max, length: 2)) == nil)
        #expect(TerminalSelectionHandle.end.moving(to: 1, in: NSRange(location: 0, length: 0)) == nil)
    }
}
