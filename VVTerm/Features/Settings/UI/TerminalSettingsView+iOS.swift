#if os(iOS)
import SwiftUI
import UIKit

struct TerminalScreenAwakeSettingRow: View {
    @AppStorage(TerminalDefaults.keepScreenAwakeKey) private var isEnabled = TerminalDefaults.defaultKeepScreenAwake

    var body: some View {
        Toggle("Keep screen awake", isOn: $isEnabled)
            .accessibilityIdentifier("vvterm.settings.terminal.keepScreenAwake")
    }
}

extension TerminalSettingsView {
    var terminalBehaviorSection: some View {
        Section("Terminal Behavior") {
            TerminalScreenAwakeSettingRow()
        }
    }

    func loadSystemFonts() -> [String] {
        var fonts = ["Menlo", "SF Mono", "Courier New"]
        let nerdFonts = [
            "JetBrainsMono Nerd Font",
            "Hack Nerd Font",
            "FiraCode Nerd Font",
            "MesloLGS Nerd Font"
        ]

        for fontFamily in nerdFonts where UIFont(name: fontFamily, size: 12) != nil {
            fonts.append(fontFamily)
        }

        return fonts.sorted()
    }

    @ViewBuilder
    var keyboardAccessorySection: some View {
        TerminalKeyboardSettingsSection(
            optionAsAltMode: optionAsAltModeBinding,
            keyboardDismissButtonEnabled: $terminalKeyboardDismissButtonEnabled
        )
    }
}

private struct TerminalKeyboardSettingsSection: View {
    @Binding var optionAsAltMode: TerminalOptionAsAltMode
    @Binding var keyboardDismissButtonEnabled: Bool
    @AppStorage(TerminalDefaults.preserveTerminalSizeForKeyboardKey) private var preserveTerminalSizeForKeyboard = false

    var body: some View {
        Section {
            Picker("Option as Alt", selection: $optionAsAltMode) {
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
}

#endif
