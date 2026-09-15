import Foundation

nonisolated struct TerminalNativeSelectionLifecycle: Equatable, Sendable {
    nonisolated enum Selection: Equatable, Sendable {
        case visible(NSRange)
        case outsideViewport
    }

    nonisolated enum Phase: Equatable, Sendable {
        case inactive
        case prepared(selection: Selection?, restoreTerminalInput: Bool)
        case interacting(selection: Selection?, restoreTerminalInput: Bool)
        case selected(selection: Selection, restoreTerminalInput: Bool)
        case restoringTerminalInput(id: UUID)
    }

    private(set) var phase: Phase = .inactive

    var selection: NSRange? {
        if case .visible(let range) = retainedSelection { return range }
        return nil
    }

    var hasSelection: Bool { retainedSelection != nil }

    private var retainedSelection: Selection? {
        switch phase {
        case .prepared(let selection, _), .interacting(let selection, _):
            selection
        case .selected(let range, _):
            range
        case .inactive, .restoringTerminalInput:
            nil
        }
    }

    var interactionIsActive: Bool {
        if case .interacting = phase {
            return true
        }
        return false
    }

    var keepsFirstResponder: Bool {
        switch phase {
        case .prepared, .interacting, .selected:
            true
        case .inactive, .restoringTerminalInput:
            false
        }
    }

    var shouldRefreshSnapshot: Bool {
        interactionIsActive || hasSelection
    }

    mutating func prepare(restoreTerminalInput: Bool) {
        phase = .prepared(
            selection: retainedSelection,
            restoreTerminalInput: shouldRestoreTerminalInput || restoreTerminalInput
        )
    }

    mutating func beginInteraction(restoreTerminalInput: Bool) {
        phase = .interacting(
            selection: retainedSelection,
            restoreTerminalInput: shouldRestoreTerminalInput || restoreTerminalInput
        )
    }

    mutating func endInteraction(restorationID: UUID = UUID()) -> UUID? {
        if let selection = retainedSelection {
            phase = .selected(
                selection: selection,
                restoreTerminalInput: shouldRestoreTerminalInput
            )
            return nil
        }
        return beginRestorationIfNeeded(id: restorationID)
    }

    mutating func setSelection(
        _ selection: NSRange?,
        restorationID: UUID = UUID()
    ) -> UUID? {
        setProjection(selection.flatMap { $0.length > 0 ? .visible($0) : nil }, restorationID: restorationID)
    }

    mutating func setProjection(
        _ selection: Selection?, restorationID: UUID = UUID()
    ) -> UUID? {
        switch phase {
        case .prepared(_, let restoreTerminalInput):
            phase = .prepared(selection: selection, restoreTerminalInput: restoreTerminalInput)
        case .interacting(_, let restoreTerminalInput):
            phase = .interacting(selection: selection, restoreTerminalInput: restoreTerminalInput)
        case .selected(_, let restoreTerminalInput):
            if let selection {
                phase = .selected(selection: selection, restoreTerminalInput: restoreTerminalInput)
            } else {
                return beginRestorationIfNeeded(id: restorationID)
            }
        case .inactive, .restoringTerminalInput:
            if let selection {
                phase = .selected(selection: selection, restoreTerminalInput: false)
            }
        }
        return nil
    }

    mutating func cancel() {
        phase = .inactive
    }

    mutating func completeRestoration(id: UUID) -> Bool {
        guard case .restoringTerminalInput(let pendingID) = phase,
              pendingID == id else {
            return false
        }
        phase = .inactive
        return true
    }

    private var shouldRestoreTerminalInput: Bool {
        switch phase {
        case .prepared(_, let restore),
             .interacting(_, let restore),
             .selected(_, let restore):
            restore
        case .inactive, .restoringTerminalInput:
            false
        }
    }

    private mutating func beginRestorationIfNeeded(id: UUID) -> UUID? {
        guard shouldRestoreTerminalInput else {
            phase = .inactive
            return nil
        }
        phase = .restoringTerminalInput(id: id)
        return id
    }
}

#if os(iOS)
import UIKit

final class TerminalNativeTextPosition: UITextPosition {
    let offset: Int
    let documentID: UUID?

    init(offset: Int, documentID: UUID? = nil) {
        self.offset = offset
        self.documentID = documentID
        super.init()
    }
}

final class TerminalNativeTextRange: UITextRange {
    let startPosition: TerminalNativeTextPosition
    let endPosition: TerminalNativeTextPosition

    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { startPosition.offset == endPosition.offset }

    var nsRange: NSRange {
        let location = max(startPosition.offset, 0)
        let end = max(endPosition.offset, location)
        let subtraction = end.subtractingReportingOverflow(location)
        return NSRange(
            location: location,
            length: subtraction.overflow ? Int.max : subtraction.partialValue
        )
    }

    init(start: Int, end: Int, documentID: UUID? = nil) {
        let lowerBound = min(start, end)
        let upperBound = max(start, end)
        self.startPosition = TerminalNativeTextPosition(offset: lowerBound, documentID: documentID)
        self.endPosition = TerminalNativeTextPosition(offset: upperBound, documentID: documentID)
        super.init()
    }
}

final class TerminalNativeSelectionRect: UITextSelectionRect {
    private let storedRect: CGRect
    private let storedContainsStart: Bool
    private let storedContainsEnd: Bool

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        self.storedRect = rect
        self.storedContainsStart = containsStart
        self.storedContainsEnd = containsEnd
        super.init()
    }

    override var rect: CGRect { storedRect }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { storedContainsStart }
    override var containsEnd: Bool { storedContainsEnd }
    override var isVertical: Bool { false }

    @available(iOS 17.4, *)
    override var transform: CGAffineTransform { .identity }
}

struct TerminalNativeFindDecoration {
    let range: NSRange
    let style: UITextSearchFoundTextStyle
}

final class TerminalNativeFindOverlayView: UIView {
    struct Highlight {
        let rect: CGRect
        let style: UITextSearchFoundTextStyle
    }

    var highlights: [Highlight] = [] {
        didSet {
            isHidden = highlights.isEmpty
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isHidden = true
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        for highlight in highlights where highlight.style == .found {
            let path = UIBezierPath(roundedRect: highlight.rect.insetBy(dx: 1, dy: 2), cornerRadius: 4)
            context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.16).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
        }

        for highlight in highlights where highlight.style == .highlighted {
            let path = UIBezierPath(roundedRect: highlight.rect.insetBy(dx: 1, dy: 1), cornerRadius: 4)
            context.setFillColor(UIColor.systemOrange.withAlphaComponent(0.24).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()

            context.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1)
            context.addPath(path.cgPath)
            context.strokePath()
        }
    }
}

nonisolated struct TerminalNativeTextSnapshot: Sendable {
    nonisolated struct Cell: Equatable, Sendable {
        let range: NSRange
        let row: Int
        let column: Int
        let width: Int
    }

    nonisolated struct Line: Sendable {
        let text: String
        let startOffset: Int
        let utf16Length: Int
        let cells: ArraySlice<Cell>?
    }

    static let empty = TerminalNativeTextSnapshot(lines: [], cellSize: CGSize(width: 1, height: 1), columns: 1)

    let documentID: UUID
    let lines: [Line]
    let text: String
    let cellSize: CGSize
    let columns: Int
    let selectionStartIsVisible: Bool
    let selectionEndIsVisible: Bool

    private var nsText: NSString {
        text as NSString
    }

    init(lines rawLines: [String], cellSize: CGSize, columns: Int, cells: [Cell]? = nil, documentID: UUID = UUID(), selectionStartIsVisible: Bool = true, selectionEndIsVisible: Bool = true) {
        let sanitizedCellSize = CGSize(width: max(cellSize.width, 1), height: max(cellSize.height, 1))
        self.cellSize = sanitizedCellSize
        self.columns = max(columns, 1)
        self.documentID = documentID
        self.selectionStartIsVisible = selectionStartIsVisible
        self.selectionEndIsVisible = selectionEndIsVisible

        var runningOffset = 0
        var cellIndex = 0
        var builtLines: [Line] = []
        for (index, line) in rawLines.enumerated() {
            let utf16Length = (line as NSString).length
            let cellStart = cellIndex
            if let cells {
                while cellIndex < cells.count, cells[cellIndex].row == index { cellIndex += 1 }
            }
            builtLines.append(Line(
                text: line, startOffset: runningOffset, utf16Length: utf16Length,
                cells: cells.map { $0[cellStart..<cellIndex] }
            ))
            runningOffset += utf16Length
            if index < rawLines.count - 1 {
                runningOffset += 1
            }
        }

        self.lines = builtLines
        self.text = rawLines.joined(separator: "\n")
    }

    var length: Int {
        nsText.length
    }

    func clampedOffset(_ offset: Int) -> Int {
        min(max(offset, 0), length)
    }

    func clampedRange(_ range: NSRange) -> NSRange {
        let location = clampedOffset(range.location)
        let rangeLength = min(max(range.length, 0), max(length - location, 0))
        return NSRange(location: location, length: rangeLength)
    }

    func upperBound(of range: NSRange) -> Int {
        let clamped = clampedRange(range)
        let addition = clamped.location.addingReportingOverflow(clamped.length)
        return addition.overflow ? length : addition.partialValue
    }

    @MainActor func nativeRange(from range: UITextRange?) -> NSRange? {
        guard let range = range as? TerminalNativeTextRange,
              range.startPosition.documentID == documentID,
              range.endPosition.documentID == documentID else { return nil }
        return clampedRange(range.nsRange)
    }

    @MainActor func nativeRange(_ range: NSRange?) -> TerminalNativeTextRange? {
        guard let range else { return nil }
        let clamped = clampedRange(range)
        return TerminalNativeTextRange(start: clamped.location, end: upperBound(of: clamped), documentID: documentID)
    }

    func text(in range: NSRange) -> String? {
        guard length > 0 else { return nil }
        let clamped = clampedRange(range)
        guard clamped.length > 0 else { return "" }
        return nsText.substring(with: clamped)
    }

    func offset(for point: CGPoint) -> Int {
        guard !lines.isEmpty else { return 0 }
        guard point.x.isFinite, point.y.isFinite else { return 0 }
        let row = Int(min(max(floor(point.y / cellSize.height), 0), CGFloat(lines.count - 1)))
        let column = Int(min(max(floor(point.x / cellSize.width), 0), CGFloat(columns)))
        let line = lines[row]
        if let cells = line.cells {
            return cells.first { $0.column + $0.width > column }?.range.location
                ?? (line.startOffset + line.utf16Length)
        }
        return clampedOffset(line.startOffset + min(column, line.utf16Length))
    }

    func characterRange(at point: CGPoint) -> NSRange? {
        guard length > 0, !lines.isEmpty else { return nil }
        let offset = offset(for: point)
        let (lineIndex, column) = lineAndColumn(for: offset)
        let line = lines[lineIndex]
        if let cells = line.cells {
            return cells.first { NSLocationInRange(offset, $0.range) }?.range
        }
        guard line.utf16Length > 0 else { return nil }
        let clampedColumn = min(column, max(line.utf16Length - 1, 0))
        return NSRange(location: line.startOffset + clampedColumn, length: 1)
    }

    func caretRect(for offset: Int) -> CGRect {
        let (lineIndex, _) = lineAndColumn(for: offset)
        let column = gridColumn(for: offset, row: lineIndex, end: false)
        let caretWidth = max(2, cellSize.width * 0.08)
        return CGRect(
            x: CGFloat(min(column, columns)) * cellSize.width,
            y: CGFloat(lineIndex) * cellSize.height,
            width: caretWidth,
            height: cellSize.height
        ).integral
    }

    @MainActor func firstRect(for range: NSRange) -> CGRect {
        let rects = selectionRects(for: range)
        if let firstRect = rects.first?.rect {
            return firstRect
        }
        return caretRect(for: range.location)
    }

    @MainActor func selectionRects(for range: NSRange) -> [TerminalNativeSelectionRect] {
        let clamped = clampedRange(range)
        guard clamped.length > 0, !lines.isEmpty else { return [] }

        let lowerBound = clamped.location
        let upperBound = self.upperBound(of: clamped)
        var rects: [TerminalNativeSelectionRect] = []

        for (lineIndex, line) in lines.enumerated() {
            let lineStart = line.startOffset
            let lineEnd = line.startOffset + line.utf16Length
            let selectionStart = max(lowerBound, lineStart)
            let selectionEnd = min(upperBound, lineEnd)
            guard selectionEnd > selectionStart else { continue }

            let startColumn = gridColumn(for: selectionStart, row: lineIndex, end: false)
            let endColumn = gridColumn(for: selectionEnd, row: lineIndex, end: true)
            let width = max(CGFloat(endColumn - startColumn) * cellSize.width, cellSize.width)
            let rect = CGRect(
                x: CGFloat(startColumn) * cellSize.width,
                y: CGFloat(lineIndex) * cellSize.height,
                width: width,
                height: cellSize.height
            ).integral
            rects.append(
                TerminalNativeSelectionRect(
                    rect: rect,
                    containsStart: selectionStartIsVisible && selectionStart == lowerBound,
                    containsEnd: selectionEndIsVisible && selectionEnd == upperBound
                )
            )
        }

        return rects
    }

    @MainActor func searchRanges(
        query: String,
        options: UITextSearchOptions
    ) -> [NSRange] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, length > 0 else { return [] }

        let queryLength = (normalizedQuery as NSString).length
        guard queryLength > 0 else { return [] }

        var results: [NSRange] = []
        var searchRange = NSRange(location: 0, length: length)

        while searchRange.length > 0 {
            let foundRange = nsText.range(of: normalizedQuery, options: options.stringCompareOptions, range: searchRange)
            guard foundRange.location != NSNotFound else { break }

            if matchesWordMethod(foundRange, method: options.wordMatchMethod) {
                results.append(foundRange)
            }

            let nextLocation = foundRange.location + max(foundRange.length, 1)
            guard nextLocation < length else { break }
            searchRange = NSRange(location: nextLocation, length: length - nextLocation)
        }

        return results
    }

    private func gridColumn(for offset: Int, row: Int, end: Bool) -> Int {
        guard let rowCells = lines[row].cells else {
            return min(lineAndColumn(for: offset).column, columns)
        }
        if end, let cell = rowCells.last(where: { $0.range.location < offset }) {
            return min(cell.column + cell.width, columns)
        }
        if let cell = rowCells.first(where: { NSMaxRange($0.range) > offset }) {
            return cell.column
        }
        return rowCells.last.map { min($0.column + $0.width, columns) } ?? 0
    }

    func lineAndColumn(for offset: Int) -> (line: Int, column: Int) {
        guard !lines.isEmpty else { return (0, 0) }

        let clamped = clampedOffset(offset)
        for (index, line) in lines.enumerated() {
            let lineStart = line.startOffset
            let lineEnd = line.startOffset + line.utf16Length

            if clamped < lineEnd {
                return (index, clamped - lineStart)
            }

            if clamped == lineEnd {
                return (index, line.utf16Length)
            }
        }

        let lastLine = lines[lines.count - 1]
        return (lines.count - 1, lastLine.utf16Length)
    }

    private func matchesWordMethod(_ range: NSRange, method: UITextSearchOptions.WordMatchMethod) -> Bool {
        switch method {
        case .contains:
            return true
        case .startsWith:
            return isWordBoundaryBeforeUTF16Offset(range.location)
        case .fullWord:
            return isWordBoundaryBeforeUTF16Offset(range.location)
                && isWordBoundaryAfterUTF16Offset(range.location + range.length)
        @unknown default:
            return true
        }
    }

    private func isWordBoundaryBeforeUTF16Offset(_ offset: Int) -> Bool {
        guard offset > 0, offset <= length else { return true }
        let previousCodeUnit = nsText.character(at: offset - 1)
        guard let scalar = UnicodeScalar(previousCodeUnit) else { return true }
        return !Self.wordScalars.contains(scalar)
    }

    private func isWordBoundaryAfterUTF16Offset(_ offset: Int) -> Bool {
        guard offset >= 0, offset < length else { return true }
        let nextCodeUnit = nsText.character(at: offset)
        guard let scalar = UnicodeScalar(nextCodeUnit) else { return true }
        return !Self.wordScalars.contains(scalar)
    }

    private static let wordScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
}
#endif
