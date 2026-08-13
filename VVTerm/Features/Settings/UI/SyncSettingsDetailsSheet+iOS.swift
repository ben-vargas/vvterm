#if os(iOS)
import SwiftUI

extension View {
    func syncSettingsDetailsPresentation() -> some View {
        presentationDetents([.medium, .large])
    }
}
#endif
