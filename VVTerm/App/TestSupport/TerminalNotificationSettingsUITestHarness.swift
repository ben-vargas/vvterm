#if DEBUG
import SwiftUI
import Combine

struct TerminalNotificationSettingsUITestHarness: View {
    @StateObject private var client = SettingsNotificationClient()

    var body: some View {
        Form {
            TerminalNotificationSettingsSection(client: client)
        }
        .defaultAppStorage(client.defaults)
        .formStyle(.grouped)
    }
}

@MainActor
private final class SettingsNotificationClient: ObservableObject, TerminalNotificationSending {
    let defaults: UserDefaults

    init() {
        let suite = "app.vivy.vvterm.notification-settings-ui-test"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func authorization() async -> TerminalNotificationAuthorization { .authorized }
    func requestAuthorization() async -> TerminalNotificationAuthorization { .authorized }
    func post(_ content: TerminalNotificationContent, context: TerminalNotificationContext) {}
}
#endif
