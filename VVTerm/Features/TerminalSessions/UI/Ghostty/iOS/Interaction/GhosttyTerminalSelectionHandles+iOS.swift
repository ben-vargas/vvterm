#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    @available(iOS 17.0, *)
    func nativeSelectionHandle(at point: CGPoint) -> TerminalSelectionHandle? {
        guard nativeSelectedRange != nil,
              let display = imeProxyTextView.interactions.compactMap({ $0 as? UITextSelectionDisplayInteraction }).first else { return nil }
        let candidates = zip([TerminalSelectionHandle.start, .end], display.handleViews).compactMap { edge, view -> (TerminalSelectionHandle, CGFloat)? in
            let visible = edge == .start ? nativeSelectionSnapshot.selectionStartIsVisible : nativeSelectionSnapshot.selectionEndIsVisible
            guard visible, !view.isHidden, !view.bounds.isEmpty else { return nil }
            let rect = view.convert(view.bounds, to: self)
            guard rect.insetBy(dx: -20, dy: -20).contains(point) else { return nil }
            return (edge, hypot(point.x - rect.midX, point.y - rect.midY))
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    @objc func handleNativeSelectionHandlePan(_ recognizer: UIPanGestureRecognizer) {
        guard #available(iOS 17.0, *) else { return }
        switch recognizer.state {
        case .began:
            guard let drag = nativeSelectionHandleDrag else { return }
            freeNativeSelectionDragAnchor()
            guard let surface = surface?.unsafeCValue,
                  let anchor = ghostty_surface_selection_anchor_new_endpoint(surface, drag.handle == .start) else { return }
            nativeSelectionDragAnchor = anchor
            nativeSelectionHandleDrag = drag
            stopMomentumScrolling()
            dismissEditMenuIfNeeded()
            nativeSelectionLifecycle.beginInteraction(restoreTerminalInput: isTerminalTextInputActive)
            moveNativeSelectionHandle(recognizer)
        case .changed:
            moveNativeSelectionHandle(recognizer)
        case .ended, .cancelled, .failed:
            guard nativeSelectionHandleDrag != nil else { return }
            if recognizer.state == .ended { moveNativeSelectionHandle(recognizer) }
            finishNativeSelectionInteraction(presentingMenuAt: recognizer.state == .ended ? recognizer.location(in: self) : nil)
        default:
            break
        }
    }

    private func moveNativeSelectionHandle(_ recognizer: UIPanGestureRecognizer) {
        guard nativeSelectionHandleDrag != nil, nativeSelectionDragAnchor != nil else { return }
        let point = recognizer.location(in: self)
        moveNativeSelectionHandle(to: point)
        updateSelectionAutoscroll(location: point, mods: [])
    }

    func moveNativeSelectionHandle(to point: CGPoint) {
        guard let drag = nativeSelectionHandleDrag, let anchor = nativeSelectionDragAnchor else { return }
        refreshNativeSelectionSnapshot()
        let point = clampedSelectionAutoscrollLocation(point)
        let offset = nativeSelectionSnapshot.offset(for: CGPoint(x: point.x + drag.touchOffset.x, y: point.y + drag.touchOffset.y))
        let handle: TerminalSelectionHandle
        let fixedEndIsVisible = drag.handle == .start ? nativeSelectionSnapshot.selectionEndIsVisible : nativeSelectionSnapshot.selectionStartIsVisible
        if fixedEndIsVisible, let range = nativeSelectedRange {
            guard let moved = drag.handle.moving(to: offset, in: range) else { return }
            handle = moved.handle
        } else {
            handle = drag.handle
        }
        // The fixed endpoint is a buffer pin, including while it is outside the viewport.
        let target = handle == .end ? max(0, offset - 1) : offset
        guard target < nativeSelectionSnapshot.length else { return }
        if applyNativeSelectionRange(NSRange(location: target, length: 1), anchor: anchor) {
            nativeSelectionHandleDrag?.handle = handle
        }
    }
}
#endif
