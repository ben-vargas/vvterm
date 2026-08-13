#if os(macOS)
import SwiftUI

extension TrustedHostsSettingsView {
    func platformHostRow(for knownHost: KnownHostSettingsItem) -> some View {
        HStack(spacing: 8) {
            TrustedHostSettingsRow(knownHost: knownHost)
            hostActionsMenu(for: knownHost)
        }
        .contextMenu {
            resetAction(for: knownHost)
        }
    }
}
#endif
