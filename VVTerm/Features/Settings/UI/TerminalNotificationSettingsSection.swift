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

    @AppStorage(TerminalNotificationPreferences.enabledKey)
    private var enabled = TerminalNotificationPreferences.defaultEnabled

    private var isOn: Binding<Bool> {
        Binding(
            get: { enabled && state == .ready(.authorized) },
            set: { value in
                enabled = value
                if value, state != .ready(.authorized) { state = .requesting }
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Notifications", isOn: isOn)
                .toggleStyle(.switch)
                .disabled(state == .loading || state == .requesting || client == nil)
                .accessibilityIdentifier("vvterm.settings.notifications")
        } footer: {
            if state == .ready(.denied) {
                Text("Allow notifications for VVTerm in system settings.")
            } else if state == .ready(.unavailable) {
                Text("Notifications are unavailable.")
            }
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
