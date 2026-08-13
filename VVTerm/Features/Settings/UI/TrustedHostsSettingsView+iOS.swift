#if os(iOS)
import SwiftUI

extension TrustedHostsSettingsView {
    func platformHostRow(for knownHost: KnownHostSettingsItem) -> some View {
        HStack(spacing: 8) {
            TrustedHostSettingsRow(knownHost: knownHost)
            hostActionsMenu(for: knownHost)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            resetAction(for: knownHost)
        }
    }
}
#endif
