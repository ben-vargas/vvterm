import SwiftUI

struct ServerWakeActionButton: View {
    let serverID: UUID
    let onAction: () -> Void

    var body: some View {
        Button(action: onAction) {
            Label("Wake Server", systemImage: "power")
        }
        .accessibilityIdentifier(
            "vvterm.serverList.wake.\(serverID.uuidString)"
        )
    }
}
