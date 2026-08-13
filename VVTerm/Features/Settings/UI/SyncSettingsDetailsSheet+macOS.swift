#if os(macOS)
import SwiftUI

extension View {
    func syncSettingsDetailsPresentation() -> some View {
        frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 620)
    }
}
#endif
