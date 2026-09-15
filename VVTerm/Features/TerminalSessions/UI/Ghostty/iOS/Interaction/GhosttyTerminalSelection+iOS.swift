//
//  GhosttyTerminalSelection+iOS.swift
//  VVTerm
//
//  iOS native selection routing.
//

#if os(iOS)
import UIKit

// MARK: - Native Text Selection

extension GhosttyTerminalView: UITextInteractionDelegate {
    func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
        guard canInteractWithTerminalContent, hasActiveSelectionInteraction else { return false }
        nativeSelectionLifecycle.prepare(restoreTerminalInput: isTerminalTextInputActive)
        refreshNativeSelectionSnapshot()
        guard nativeSelectionSnapshot.length > 0 else {
            nativeSelectionLifecycle.cancel()
            return false
        }
        return true
    }

    func interactionWillBegin(_ interaction: UITextInteraction) {
        let terminalInputWasActive = isTerminalTextInputActive
        nativeSelectionLifecycle.beginInteraction(restoreTerminalInput: terminalInputWasActive)
        if !isTerminalTextInputActive {
            _ = becomeFirstResponder()
        }
        refreshNativeSelectionSnapshot()
    }

    func interactionDidEnd(_ interaction: UITextInteraction) {
        let restorationID = nativeSelectionLifecycle.endInteraction()
        refreshNativeSelectionSnapshot()
        scheduleNativeSelectionTerminalInputRestoration(restorationID)
    }
}

extension GhosttyTerminalView {
    @objc func handleNativeSelectionLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            let point = recognizer.location(in: self)
            beginNativeSelection(at: point)
            updateSelectionAutoscroll(location: point, mods: [])
        case .changed:
            let point = recognizer.location(in: self)
            extendNativeSelection(to: point)
            updateSelectionAutoscroll(location: point, mods: [])
        case .ended:
            finishNativeSelectionInteraction(
                presentingMenuAt: recognizer.location(in: self)
            )
        case .cancelled, .failed:
            freeNativeSelectionDragAnchor()
            if !nativeSelectionLifecycle.hasSelection {
                nativeSelectionLifecycle.cancel()
            } else {
                finishNativeSelectionInteraction(presentingMenuAt: nil)
            }
        default:
            break
        }
    }

    private func beginNativeSelection(at point: CGPoint) {
        selectNativeText(at: point, granularity: .word, keepsDragAnchor: true)
    }

    @objc private func handleNativeSelectionMultiTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              canInteractWithTerminalContent else {
            return
        }
        let granularity: UITextGranularity = recognizer.numberOfTapsRequired >= 3
            ? .paragraph
            : .word
        selectNativeText(
            at: recognizer.location(in: self),
            granularity: granularity,
            keepsDragAnchor: false
        )
        finishNativeSelectionInteraction(
            presentingMenuAt: recognizer.location(in: self)
        )
    }

    private func selectNativeText(
        at point: CGPoint,
        granularity: UITextGranularity,
        keepsDragAnchor: Bool
    ) {
        stopMomentumScrolling()
        freeNativeSelectionDragAnchor()
        nativeSelectionLifecycle.prepare(restoreTerminalInput: isTerminalTextInputActive)
        nativeSelectionLifecycle.beginInteraction(restoreTerminalInput: isTerminalTextInputActive)
        refreshNativeSelectionSnapshot()
        guard nativeSelectionSnapshot.length > 0 else {
            freeNativeSelectionDragAnchor()
            nativeSelectionLifecycle.cancel()
            return
        }

        let offset = nativeSelectionSnapshot.offset(for: point)
        let position = TerminalNativeTextPosition(offset: offset, documentID: nativeSelectionSnapshot.documentID)
        let direction = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let tokenRange = imeProxyTextView.tokenizer.rangeEnclosingPosition(
            position,
            with: granularity,
            inDirection: direction
        )
        let range = nativeSelectionSnapshot.nativeRange(from: tokenRange)
            ?? nativeSelectionSnapshot.characterRange(at: point)
        setNativeSelectedRange(range)
        if keepsDragAnchor, let surface = surface?.unsafeCValue {
            nativeSelectionDragAnchor = ghostty_surface_selection_anchor_new(surface)
        }
    }

    func extendNativeSelection(to point: CGPoint) {
        refreshNativeSelectionSnapshot()
        guard nativeSelectionLifecycle.hasSelection,
              let anchor = nativeSelectionDragAnchor,
              let target = nativeSelectionSnapshot.characterRange(at: clampedSelectionAutoscrollLocation(point)) else {
            return
        }
        applyNativeSelectionRange(target, anchor: anchor)
    }

    func finishNativeSelectionInteraction(presentingMenuAt point: CGPoint?) {
        freeNativeSelectionDragAnchor()
        if nativeSelectionLifecycle.interactionIsActive {
            let restorationID = nativeSelectionLifecycle.endInteraction()
            scheduleNativeSelectionTerminalInputRestoration(restorationID)
        }
        if let point, (nativeSelectionLifecycle.selection?.length ?? 0) > 0 {
            presentNativeSelectionEditMenu(at: point)
        }
    }

    func setupNativeTextSelectionInteractions() {
        scrollRecognizer.require(toFail: nativeSelectionLongPressRecognizer)
        if #available(iOS 17.0, *) {
            let display = TerminalSelectionDisplayInteraction(textInput: imeProxyTextView, delegate: self)
            // Ghostty owns selection changes; UIKit supplies their visual presentation.
            display.highlightView.alpha = 0
            display.isActivated = false
            imeProxyTextView.addInteraction(display)
            imeProxyTextView.addGestureRecognizer(nativeSelectionHandlePanRecognizer)
        } else {
            let interaction = UITextInteraction(for: .editable)
            interaction.delegate = self
            interaction.textInput = imeProxyTextView
            imeProxyTextView.addInteraction(interaction)
            nativeTextInteraction = interaction
            for gesture in interaction.gesturesForFailureRequirements {
                scrollRecognizer.require(toFail: gesture)
            }
        }

        let nativeSelectionDoubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleNativeSelectionMultiTap(_:))
        )
        nativeSelectionDoubleTap.numberOfTapsRequired = 2
        nativeSelectionDoubleTap.cancelsTouchesInView = false
        nativeSelectionDoubleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        nativeSelectionDoubleTap.delegate = self

        let nativeSelectionTripleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleNativeSelectionMultiTap(_:))
        )
        nativeSelectionTripleTap.numberOfTapsRequired = 3
        nativeSelectionTripleTap.cancelsTouchesInView = false
        nativeSelectionTripleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        nativeSelectionTripleTap.delegate = self

        nativeSelectionDoubleTap.require(toFail: nativeSelectionTripleTap)
        directTouchTapRecognizer.require(toFail: nativeSelectionDoubleTap)
        for gesture in nativeTextInteraction?.gesturesForFailureRequirements ?? [] {
            gesture.require(toFail: directTouchTapRecognizer)
            gesture.require(toFail: nativeSelectionLongPressRecognizer)
            gesture.require(toFail: nativeSelectionDoubleTap)
            gesture.require(toFail: nativeSelectionTripleTap)
        }
        imeProxyTextView.addGestureRecognizer(nativeSelectionDoubleTap)
        imeProxyTextView.addGestureRecognizer(nativeSelectionTripleTap)
    }

    func refreshNativeSelectionSnapshot(resetSelection: Bool = false) {
        guard !isPublishingNativeSelectionSnapshot,
              let surface = surface?.unsafeCValue,
              let metrics = selectionGridMetrics() else { return }
        isPublishingNativeSelectionSnapshot = true
        defer { isPublishingNativeSelectionSnapshot = false }
        var view = ghostty_selection_snapshot_s()
        guard let handle = ghostty_surface_selection_snapshot_new(surface, nativeSelectionSnapshotHandle, &view) else { return }
        let oldHandle = nativeSelectionSnapshotHandle
        nativeSelectionSnapshotHandle = handle
        defer {
            if let oldHandle { ghostty_surface_selection_snapshot_free(surface, oldHandle) }
        }
        let text = view.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(view.text_len)), as: UTF8.self) } ?? ""
        let cells = UnsafeBufferPointer(start: view.cells, count: Int(view.cells_len)).map {
            TerminalNativeTextSnapshot.Cell(
                range: NSRange(location: Int($0.offset), length: Int($0.length)),
                row: Int($0.y), column: Int($0.x), width: Int($0.width)
            )
        }
        let snapshot = TerminalNativeTextSnapshot(
            lines: text.components(separatedBy: "\n"),
            cellSize: metrics.cellSize, columns: Int(view.columns), cells: cells,
            documentID: view.unchanged ? nativeSelectionSnapshot.documentID : UUID(),
            selectionStartIsVisible: view.selection_start_visible,
            selectionEndIsVisible: view.selection_end_visible
        )
        let range = view.has_selection && view.selection_len > 0 && !resetSelection
            ? NSRange(location: Int(view.selection_start), length: Int(view.selection_len)) : nil
        let textChanged = !view.unchanged
            || nativeSelectionSnapshot.cellSize != snapshot.cellSize
        let selectionChanged = nativeSelectionLifecycle.selection != range
            || nativeSelectionSnapshot.selectionStartIsVisible != snapshot.selectionStartIsVisible
            || nativeSelectionSnapshot.selectionEndIsVisible != snapshot.selectionEndIsVisible
        if textChanged { imeProxyTextView.inputDelegate?.textWillChange(imeProxyTextView) }
        if selectionChanged { imeProxyTextView.inputDelegate?.selectionWillChange(imeProxyTextView) }
        nativeSelectionSnapshot = snapshot
        let projection: TerminalNativeSelectionLifecycle.Selection? = if let range {
            .visible(range)
        } else if view.has_selection && !resetSelection {
            .outsideViewport
        } else {
            nil
        }
        let restorationID = nativeSelectionLifecycle.setProjection(projection)
        if textChanged { imeProxyTextView.inputDelegate?.textDidChange(imeProxyTextView) }
        if selectionChanged { imeProxyTextView.inputDelegate?.selectionDidChange(imeProxyTextView) }
        if textChanged || selectionChanged { updateNativeSelectionDisplay() }
        updateNativeFindOverlay()
        if resetSelection { ghostty_surface_clear_selection(surface) }
        scheduleNativeSelectionTerminalInputRestoration(restorationID)
    }

    func updateNativeSelectionDisplay() {
        if #available(iOS 17.0, *),
           let display = imeProxyTextView.interactions.compactMap({ $0 as? UITextSelectionDisplayInteraction }).first {
            display.isActivated = nativeSelectedRange != nil
            display.layoutManagedSubviews()
        }
    }

    func freeNativeSelectionDragAnchor() {
        stopSelectionAutoscroll()
        nativeSelectionHandleDrag = nil
        if let anchor = nativeSelectionDragAnchor, let surface = surface?.unsafeCValue {
            ghostty_surface_selection_anchor_free(surface, anchor)
        }
        nativeSelectionDragAnchor = nil
    }

    func freeNativeSelectionSnapshot() {
        if let handle = nativeSelectionSnapshotHandle, let surface = surface?.unsafeCValue {
            ghostty_surface_selection_snapshot_free(surface, handle)
        }
        nativeSelectionSnapshotHandle = nil
    }

    func setNativeSelectedRange(_ range: NSRange?) {
        // Delegate notifications can synchronously return the projected range.
        guard !isPublishingNativeSelectionSnapshot,
              range != nativeSelectedRange || (range == nil && nativeSelectionLifecycle.hasSelection) else { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard let range, range.length > 0 else {
            ghostty_surface_clear_selection(surface)
            refreshNativeSelectionSnapshot()
            return
        }
        applyNativeSelectionRange(range, anchor: nil)
    }

    @discardableResult
    func applyNativeSelectionRange(_ range: NSRange, anchor: ghostty_selection_anchor_t?) -> Bool {
        guard let surface = surface?.unsafeCValue,
              let handle = nativeSelectionSnapshotHandle,
              let offset = UInt(exactly: range.location),
              let length = UInt(exactly: range.length) else { return false }
        // On concurrent output the native bridge rejects the stale range.
        // Refresh the projection; never retry old offsets against new text.
        let accepted = ghostty_surface_selection_snapshot_select(surface, handle, offset, length, anchor)
        refreshNativeSelectionSnapshot()
        return accepted
    }

    func scheduleNativeSelectionTerminalInputRestoration(_ restorationID: UUID?) {
        guard let restorationID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.nativeSelectionLifecycle.completeRestoration(id: restorationID),
                  !self.isShuttingDown,
                  self.isTextInputSessionEligible,
                  !self.isFindNavigatorActive else {
                return
            }
            _ = self.requestKeyboardFocus(for: .selectionGesture)
        }
    }

    func isPointOnNativeSelectionHandleHitArea(_ point: CGPoint) -> Bool {
        if #available(iOS 17.0, *) {
            return nativeSelectionHandle(at: point) != nil
        }
        guard let nativeSelectedRange = nativeSelectionLifecycle.selection,
              nativeSelectedRange.length > 0 else {
            return false
        }
        let clamped = nativeSelectionSnapshot.clampedRange(nativeSelectedRange)
        guard clamped.length > 0 else { return false }

        let startRect = nativeSelectionSnapshot.caretRect(for: clamped.location)
        let endRect = nativeSelectionSnapshot.caretRect(
            for: nativeSelectionSnapshot.upperBound(of: clamped)
        )
        let hitSlop = max(28, nativeSelectionSnapshot.cellSize.height * 1.5)
        return startRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
            || endRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
    }

    var usesNativeTouchSelection: Bool {
        return UIDevice.current.userInterfaceIdiom == .phone
            || UIDevice.current.userInterfaceIdiom == .pad
    }

    func selectionGridMetrics() -> (cols: Int, rows: Int, cellSize: CGSize)? {
        guard let terminalSize = terminalSize() else { return nil }
        let cols = max(Int(terminalSize.columns), 1)
        let rows = max(Int(terminalSize.rows), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : max(bounds.width / CGFloat(cols), 1)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : max(bounds.height / CGFloat(rows), 1)
        return (cols, rows, CGSize(width: resolvedCellWidth, height: resolvedCellHeight))
    }

    func currentSelectionText() -> String? {
        guard allowsHostTextSelection else { return nil }
        return ghosttySelectionText()
    }

    private func ghosttySelectionText() -> String? {
        guard let surface = surface?.unsafeCValue else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return ghosttyTextString(text)
    }

    private func ghosttyTextString(_ text: ghostty_text_s) -> String {
        guard let rawText = text.text else { return "" }
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(rawText).assumingMemoryBound(to: UInt8.self),
            count: Int(text.text_len)
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    func copyTextToClipboard(_ text: String) {
        let cleaned = TerminalTextCleaner.cleanText(text, settings: .current())
        Clipboard.copy(cleaned)
    }

    func selectAllVisibleText() {
        guard allowsHostTextSelection else { return }

        refreshNativeSelectionSnapshot()
        guard nativeSelectionSnapshot.length > 0 else { return }
        setNativeSelectedRange(NSRange(location: 0, length: nativeSelectionSnapshot.length))
    }

    func clearSelectionAfterPaste() {
        if nativeSelectedRange != nil {
            setNativeSelectedRange(nil)
        }
    }
}

@available(iOS 17.0, *)
extension GhosttyTerminalView: UITextSelectionDisplayInteractionDelegate {}

#endif
