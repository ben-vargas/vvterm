#if os(iOS)
import SwiftUI

struct TerminalKeyboardInputPlatformSettingsView: View {
    @ObservedObject var voiceSettingsStore: VoiceSettingsStore

    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var optionAsAltModeRaw = TerminalOptionAsAltMode.none.rawValue
    @AppStorage(TerminalDefaults.preserveTerminalSizeForKeyboardKey) private var preserveTerminalSizeForKeyboard = false
    @AppStorage("terminalKeyboardDismissButtonEnabled") private var keyboardDismissButtonEnabled = true

    private var optionAsAltModeBinding: Binding<TerminalOptionAsAltMode> {
        Binding(
            get: { TerminalOptionAsAltMode(rawValue: optionAsAltModeRaw) ?? .none },
            set: { optionAsAltModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Option as Alt", selection: optionAsAltModeBinding) {
                    ForEach(TerminalOptionAsAltMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("Hardware Keyboard")
            } footer: {
                Text("Choose which Option key sends Alt. The other key still types layout characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep terminal size", isOn: $preserveTerminalSizeForKeyboard)
            } header: {
                Text("Software Keyboard")
            } footer: {
                Text("Prevents tmux and other terminal apps from resizing when the keyboard opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show dismiss button", isOn: $keyboardDismissButtonEnabled)

                NavigationLink {
                    TerminalAccessoryCustomizationView()
                } label: {
                    Text("Customize Accessory Bar")
                }

                NavigationLink {
                    TerminalCustomActionLibraryView()
                } label: {
                    Text("Custom Actions")
                }
            } header: {
                Text("Accessory Bar")
            }

            Section {
                NavigationLink {
                    TerminalFloatingControlSettingsView(
                        voiceSettingsStore: voiceSettingsStore
                    )
                } label: {
                    Label("Floating Input Control", systemImage: "circle.grid.cross")
                }
            } header: {
                Text("Keyboard Hidden")
            } footer: {
                Text("Choose the controls that appear after you hide the software keyboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
    }
}
#endif
