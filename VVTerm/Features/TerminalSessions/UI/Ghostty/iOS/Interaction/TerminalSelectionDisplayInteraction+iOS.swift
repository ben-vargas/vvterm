#if os(iOS)
import UIKit

@available(iOS 17.0, *)
final class TerminalSelectionDisplayInteraction: UITextSelectionDisplayInteraction {
    override func layoutManagedSubviews() {
        super.layoutManagedSubviews()
        guard let input = textInput as? TerminalIMEProxyTextView,
              let snapshot = input.terminalOwner?.nativeSelectionSnapshot else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (visible, handle) in zip(
            [snapshot.selectionStartIsVisible, snapshot.selectionEndIsVisible], handleViews
        ) {
            if visible {
                handle.layer.mask = nil
            } else {
                // UIKit may show the handle again after layout. An empty transparent
                // mask keeps it from drawing until its buffer endpoint is visible.
                if handle.layer.mask == nil { handle.layer.mask = CALayer() }
                handle.isHidden = true
            }
        }
    }
}
#endif
