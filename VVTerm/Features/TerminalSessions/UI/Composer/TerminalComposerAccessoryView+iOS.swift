#if os(iOS)
import SwiftUI

/// Chat owns its button layout; actions use the terminal's existing dispatcher.
struct TerminalComposerAccessoryView: UIViewRepresentable {
    let snapshot: TerminalAccessoryInputSnapshot
    let onKey: (TerminalKey) -> Void
    let onCustomAction: (TerminalAccessoryCustomAction) -> Void

    func makeUIView(context: Context) -> TerminalComposerAccessoryBar {
        TerminalComposerAccessoryBar()
    }

    func updateUIView(_ view: TerminalComposerAccessoryBar, context: Context) {
        view.onKey = onKey
        view.onCustomAction = onCustomAction
        view.apply(snapshot.resolvedItems)
    }
}
#endif
