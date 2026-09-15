#if os(iOS)
import SwiftUI

struct TerminalKeyboardSafeAreaModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        // Keep the view identity stable across tab changes. Replacing a branch
        // can let an old Stats view disappear and pause the new view's collector.
        // UIKit reports bottom chrome to the terminal layout separately.
        content.ignoresSafeArea(.all, edges: isEnabled ? .bottom : [])
    }
}
#endif
