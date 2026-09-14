#if os(iOS)
import SwiftUI
import UIKit

/// Native touch handling keeps a hold alive while the recording view appears.
struct TerminalComposerVoiceControl: UIViewRepresentable {
    enum Style { case waveform, prompt }
    var style = Style.waveform
    let onTap: () -> Void
    let onHoldChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        if style == .waveform {
            button.setImage(UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
        }
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = style == .waveform ? String(localized: "Voice input") : String(localized: "Touch and hold to record")
        button.accessibilityIdentifier = style == .waveform ? "vvterm.composer.record" : "vvterm.composer.hold-prompt"
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
            switch gesture.state {
            case .began: parent.onHoldChanged(true)
            case .ended, .cancelled, .failed: parent.onHoldChanged(false)
            default: break
            }
        }
    }
}
#endif
