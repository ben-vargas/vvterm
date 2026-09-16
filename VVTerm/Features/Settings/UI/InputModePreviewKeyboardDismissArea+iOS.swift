#if os(iOS)
import SwiftUI
import UIKit

/// Observes outside taps without taking touches from the Form's controls.
struct InputModePreviewKeyboardDismissArea: UIViewRepresentable {
    let dismiss: () -> Void

    func makeUIView(context: Context) -> TapArea { TapArea() }

    func updateUIView(_ view: TapArea, context: Context) {
        view.dismiss = dismiss
    }

    static func dismantleUIView(_ view: TapArea, coordinator: ()) {
        view.detach()
    }

    final class TapArea: UIView, UIGestureRecognizerDelegate {
        var dismiss: (() -> Void)?
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(dismissPreview))

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }

        func detach() { tap.view?.removeGestureRecognizer(tap) }

        @objc private func dismissPreview() { dismiss?() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard bounds.contains(touch.location(in: self)) else { return false }
            var touchedView = touch.view
            while let view = touchedView {
                if view is UITextField || view is UITextView { return false }
                touchedView = view.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}
#endif
