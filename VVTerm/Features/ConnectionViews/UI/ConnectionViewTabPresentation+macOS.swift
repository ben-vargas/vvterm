#if os(macOS)
import SwiftUI

extension ConnectionViewTabID {
    func backgroundColor(terminalBackground: Color) -> Color {
        switch self {
        case .terminal: terminalBackground
        case .stats, .files: Color(nsColor: .windowBackgroundColor)
        }
    }
}
#endif
