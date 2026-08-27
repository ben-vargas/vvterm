import SwiftUI

extension ServerWakeAction {
    var title: LocalizedStringResource {
        switch self {
        case .wake:
            return "Wake Server"
        case .wakeAndConnect:
            return "Wake and Connect"
        }
    }

    var systemImage: String {
        switch self {
        case .wake:
            return "power"
        case .wakeAndConnect:
            return "bolt.horizontal.circle"
        }
    }
}

struct ServerWakeActionButton: View {
    let action: ServerWakeAction
    let serverID: UUID
    let onAction: (ServerWakeAction) -> Void

    var body: some View {
        Button {
            onAction(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .accessibilityIdentifier(
            "vvterm.serverList.\(action.accessibilityComponent).\(serverID.uuidString)"
        )
    }
}

private extension ServerWakeAction {
    var accessibilityComponent: String {
        switch self {
        case .wake:
            return "wake"
        case .wakeAndConnect:
            return "wakeAndConnect"
        }
    }
}
