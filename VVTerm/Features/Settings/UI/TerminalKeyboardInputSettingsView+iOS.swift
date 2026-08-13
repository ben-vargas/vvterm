#if os(iOS)
import SwiftUI

struct TerminalKeyboardInputPlatformSettingsView: View {
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

                Toggle("Keep terminal size when keyboard opens", isOn: $preserveTerminalSizeForKeyboard)
                Toggle("Show keyboard dismiss button", isOn: $keyboardDismissButtonEnabled)

                NavigationLink {
                    TerminalAccessoryCustomizationView()
                } label: {
                    Text("Customize Accessory Bar")
                }

                NavigationLink {
                    TerminalCustomActionLibraryView()
                } label: {
                    Text("Manage Custom Actions")
                }
            } header: {
                Text("Keyboard")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose which physical Option key sends Alt to terminal apps. Other Option keys remain available for keyboard-layout characters.")
                    Text("Keeping the terminal size prevents keyboard-driven window resizes in remote apps such as tmux. VVTerm moves the terminal to keep the cursor visible instead.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
    }
}
#endif
