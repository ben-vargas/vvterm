#if os(iOS)
import SwiftUI

struct TerminalKeyboardSafeAreaModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            // UIKit reports the physical bottom chrome separately to the
            // terminal layout. SwiftUI must not add/remove that inset as the
            // keyboard changes mode.
            content.ignoresSafeArea(.all, edges: .bottom)
        } else {
            content
        }
    }
}
#endif
