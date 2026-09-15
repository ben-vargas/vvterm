import Foundation

nonisolated enum TerminalSelectionHandle {
    case start, end

    func moving(to offset: Int, in range: NSRange) -> (handle: Self, range: NSRange)? {
        let upper = range.location.addingReportingOverflow(range.length)
        guard range.location >= 0, range.length > 0, !upper.overflow, offset >= 0 else { return nil }
        let fixed = self == .start ? upper.partialValue : range.location
        // Keep the range while crossing its fixed end; an empty range clears selection.
        guard offset != fixed else { return nil }
        return (
            offset < fixed ? .start : .end,
            NSRange(location: min(offset, fixed), length: max(offset, fixed) - min(offset, fixed))
        )
    }
}
