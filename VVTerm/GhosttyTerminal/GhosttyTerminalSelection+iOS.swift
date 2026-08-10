//
//  GhosttyTerminalSelection+iOS.swift
//  VVTerm
//
//  iOS native selection and edit-menu delegate routing.
//

#if os(iOS)
import UIKit

// MARK: - Native Text Selection

extension GhosttyTerminalView: UITextInteractionDelegate {
    func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
        guard TerminalSelectionRoutingPolicy.shouldAllowHostSelection(
            terminalMouseCaptured: surface?.mouseCaptured == true,
            interaction: nativeSelectionGestureInteraction
        ) else {
            return false
        }
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


// MARK: - Edit Menu Interaction Delegate

extension GhosttyTerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if editMenuPresentation == .pointerContext {
            return UIMenu(children: pointerContextMenuElements())
        }

        var actions: [UIMenuElement] = []

        if let selectionText = currentSelectionText(), !selectionText.isEmpty {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })

        return UIMenu(children: actions)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        editMenuPresentation = .selection
    }
}

extension GhosttyTerminalView {
    func setupNativeTextSelectionInteractions() {
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.delegate = self
        interaction.textInput = self
        addInteraction(interaction)
        nativeTextInteraction = interaction
        for gesture in interaction.gesturesForFailureRequirements {
            scrollRecognizer.require(toFail: gesture)
        }
    }

    private func notifyNativeSelectionLayoutChange() {
        guard nativeSelectionLifecycle.shouldRefreshSnapshot else { return }
        nativeTextInputDelegate?.textWillChange(self)
        nativeTextInputDelegate?.textDidChange(self)
        nativeTextInputDelegate?.selectionWillChange(self)
        nativeTextInputDelegate?.selectionDidChange(self)
    }

    func refreshNativeSelectionSnapshot(resetSelection: Bool = false) {
        nativeSelectionSnapshot = buildNativeSelectionSnapshot()
        updateNativeFindOverlay()
        if resetSelection {
            setNativeSelectedRange(nil)
            return
        }

        guard let nativeSelectedRange = nativeSelectionLifecycle.selection else { return }
        let clamped = nativeSelectionSnapshot.clampedRange(nativeSelectedRange)
        if clamped != nativeSelectedRange {
            setNativeSelectedRange(clamped)
        } else {
            notifyNativeSelectionLayoutChange()
        }
    }

    private func buildNativeSelectionSnapshot() -> TerminalNativeTextSnapshot {
        guard let surface = surface?.unsafeCValue,
              let metrics = selectionGridMetrics() else {
            return .empty
        }

        let rows = (0..<metrics.rows).map { readNativeSelectionLine(surface: surface, row: $0, columns: metrics.cols) }
        return TerminalNativeTextSnapshot(lines: rows, cellSize: metrics.cellSize, columns: metrics.cols)
    }

    private func readNativeSelectionLine(surface: ghostty_surface_t, row: Int, columns: Int) -> String {
        guard columns > 0,
              let wireRow = UInt32(exactly: row),
              let wireEndColumn = UInt32(exactly: columns - 1) else {
            return ""
        }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0,
                y: wireRow
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: wireEndColumn,
                y: wireRow
            ),
            rectangle: true
        )

        let rawLine: String
        if ghostty_surface_read_text(surface, selection, &text) {
            defer { ghostty_surface_free_text(surface, &text) }
            rawLine = ghosttyTextString(text)
        } else {
            rawLine = ""
        }

        var line = rawLine
        while line.last == "\n" || line.last == "\r" {
            line.removeLast()
        }

        while let scalar = line.unicodeScalars.last,
              CharacterSet.whitespaces.contains(scalar) {
            line.removeLast()
        }

        let lineNSString = line as NSString
        if lineNSString.length > columns {
            line = lineNSString.substring(to: columns)
        }

        return line
    }

    func setNativeSelectedRange(_ range: NSRange?) {
        let clampedRange = range.map { nativeSelectionSnapshot.clampedRange($0) }
        if nativeSelectionLifecycle.selection == clampedRange {
            notifyNativeSelectionLayoutChange()
            return
        }

        nativeTextInputDelegate?.selectionWillChange(self)
        let restorationID = nativeSelectionLifecycle.setSelection(clampedRange)
        nativeTextInputDelegate?.selectionDidChange(self)
        scheduleNativeSelectionTerminalInputRestoration(restorationID)
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
        guard let nativeSelectedRange = nativeSelectionLifecycle.selection,
              nativeSelectedRange.length > 0 else {
            return false
        }
        let clamped = nativeSelectionSnapshot.clampedRange(nativeSelectedRange)
        guard clamped.length > 0 else { return false }

        let startRect = nativeSelectionSnapshot.caretRect(for: clamped.location)
        let endRect = nativeSelectionSnapshot.caretRect(for: clamped.location + clamped.length)
        let hitSlop = max(28, nativeSelectionSnapshot.cellSize.height * 1.5)
        return startRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
            || endRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
    }

    private func selectedNativeSelectionText() -> String? {
        guard allowsHostTextSelection else { return nil }
        guard let nativeSelectedRange = nativeSelectionLifecycle.selection,
              nativeSelectedRange.length > 0 else { return nil }
        return nativeSelectionSnapshot.text(in: nativeSelectedRange)
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

    func dismissEditMenuIfNeeded() {
        editMenuInteraction?.dismissMenu()
    }

    func currentSelectionText() -> String? {
        guard allowsHostTextSelection else { return nil }

        if let nativeSelectionText = selectedNativeSelectionText() {
            return nativeSelectionText
        }
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

    func normalizedSelectionMenuText() -> String? {
        guard let text = currentSelectionText()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private func selectionMenuSourceRect() -> CGRect {
        if let selectedTextRange {
            let rect = firstRect(for: selectedTextRange)
            if !rect.isNull, !rect.isEmpty {
                return rect
            }
        }
        return CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
    }

    func nearestPresentingViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController.topMostPresentedViewController
            }
            responder = current.next
        }
        return window?.rootViewController?.topMostPresentedViewController
    }

    private func presentSelectionMenuController(_ controller: UIViewController) {
        guard let presenter = nearestPresentingViewController() else { return }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = selectionMenuSourceRect()
        }
        presenter.present(controller, animated: true)
    }

    private func presentShareSheet(for text: String) {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        presentSelectionMenuController(controller)
    }

    private func presentDictionaryLookup(for text: String) {
        guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: text) else { return }
        let controller = UIReferenceLibraryViewController(term: text)
        presentSelectionMenuController(controller)
    }

    private func searchWeb(for text: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components?.url else { return }
        UIApplication.shared.open(url)
    }

    @available(iOS 16.0, *)
    func nativeSelectionMenuElements() -> [UIMenuElement] {
        let selectionText = allowsHostTextSelection ? normalizedSelectionMenuText() : nil
        var actions: [UIMenuElement] = []

        if selectionText != nil {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })

        if allowsHostTextSelection, nativeSelectionSnapshot.length > 0 || selectionGridMetrics() != nil {
            actions.append(UIAction(title: String(localized: "Select All"), image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                self?.selectAll(nil)
            })
        }

        if selectionText != nil {
            actions.append(UIAction(title: String(localized: "Find"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.presentFindNavigator(prefillingSelectedText: true)
            })
        }

        return actions
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

#endif
