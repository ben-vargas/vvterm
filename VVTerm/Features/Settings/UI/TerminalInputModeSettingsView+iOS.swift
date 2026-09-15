#if os(iOS)
import SwiftUI

struct TerminalInputModeSettingsView: View {
    @AppStorage(TerminalInputMode.preferenceKey) private var inputMode = TerminalInputMode.direct

    var body: some View {
        Form {
            Section("Preview") {
                TerminalInputModePreview(mode: inputMode)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                Picker("Input Mode", selection: $inputMode) {
                    Text("Normal Mode").tag(TerminalInputMode.direct)
                    Text("Chat Mode").tag(TerminalInputMode.chat)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("vvterm.input-mode")
            } footer: {
                switch inputMode {
                case .direct:
                    Text("Type directly in the terminal. Attachments are sent immediately.")
                case .chat:
                    Text("Review text and attachments before sending. Choose what the Send button does.")
                }
            }
            TerminalKeyboardSettings()
            if inputMode == .chat {
                Section {
                    NavigationLink("Send Actions") { TerminalComposerSendActionsSettingsView() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Input Mode")
        .adaptiveSoftScrollEdges()
    }
}
#endif
