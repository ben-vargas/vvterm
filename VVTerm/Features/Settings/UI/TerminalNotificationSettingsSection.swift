import SwiftUI

struct TerminalNotificationSettingsSection: View {
    let client: (any TerminalNotificationSending)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: State = .loading

    private enum State: Hashable {
        case loading
        case requesting
        case ready(TerminalNotificationAuthorization)
    }

    var body: some View {
        Section {
            switch state {
            case .loading, .requesting:
                ProgressView()
            case .ready(.notDetermined):
                Button("Allow Terminal Notifications") { state = .requesting }
            case .ready(.authorized):
                Label("Terminal notifications are allowed", systemImage: "checkmark")
            case .ready(.denied):
                Text("Allow notifications for VVTerm in system settings.")
            case .ready(.unavailable):
                Text("Notifications are unavailable.")
            }
        } header: {
            Text("Terminal Notifications")
        } footer: {
            Text("Remote programs can send notifications while VVTerm receives terminal output. Mosh does not support these messages.")
        }
        .task(id: state) {
            switch state {
            case .loading:
                let result = await client?.authorization() ?? .unavailable
                if !Task.isCancelled { state = .ready(result) }
            case .requesting:
                let result = await client?.requestAuthorization() ?? .unavailable
                if !Task.isCancelled { state = .ready(result) }
            case .ready: break
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, state != .requesting { state = .loading }
        }
    }
}
