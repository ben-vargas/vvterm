#if os(iOS)
import SwiftUI

struct TerminalInputModeSettingsView: View {
    @AppStorage(TerminalInputMode.preferenceKey) private var inputMode = TerminalInputMode.direct

    @AppStorage(TerminalInputMode.chatAccessoryPreferenceKey) private var chatAccessoryEnabled = false

    var body: some View {
        Form {
            Section("Preview") {
                TerminalInputModePreview(mode: inputMode, showsChatAccessory: chatAccessoryEnabled)
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
            if inputMode == .chat {
                Section {
                    NavigationLink("Customize Send Action") { TerminalComposerSendActionsSettingsView() }
                    Toggle("Show Accessory Bar", isOn: $chatAccessoryEnabled)
                        .accessibilityIdentifier("vvterm.chat.accessory")
                } footer: {
                    Text("Accessory keys and custom actions go directly to the terminal.")
                }
            }
            TerminalKeyboardSettings()
        }
        .formStyle(.grouped)
        .navigationTitle("Input Mode")
        .adaptiveSoftScrollEdges()
    }
}
#endif
