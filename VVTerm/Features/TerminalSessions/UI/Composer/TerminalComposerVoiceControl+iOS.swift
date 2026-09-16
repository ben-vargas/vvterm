#if os(iOS)
import SwiftUI
import UIKit

/// Native gestures distinguish a tap from the hold that starts recording.
struct TerminalComposerVoiceControl: UIViewRepresentable {
    enum Style { case microphone, prompt }
    var style = Style.microphone
    let onTap: () -> Void
    let onHold: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        if style == .microphone {
            button.setImage(UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)), for: .normal)
        }
        button.tintColor = .label
        button.accessibilityLabel = style == .microphone ? String(localized: "Voice input") : String(localized: "Touch and hold to record")
        button.accessibilityIdentifier = style == .microphone ? "vvterm.composer.record" : "vvterm.composer.hold-prompt"
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.25
        button.addGestureRecognizer(hold)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: TerminalComposerVoiceControl
        init(_ parent: TerminalComposerVoiceControl) { self.parent = parent }
        @objc func tapped() { parent.onTap() }
        @objc func held(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { parent.onHold() }
        }
    }
}
#endif
