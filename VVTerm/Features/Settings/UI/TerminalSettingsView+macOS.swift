#if os(macOS)
import AppKit
import SwiftUI

extension TerminalSettingsView {
    @ViewBuilder
    var terminalBehaviorSection: some View {
        EmptyView()
    }

    func loadSystemFonts() -> [String] {
        let fontManager = NSFontManager.shared
        return fontManager.availableFontFamilies.filter { familyName in
            guard let font = NSFont(name: familyName, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }

    var keyboardAccessorySection: some View {
        Section {
            Picker("Option as Alt", selection: optionAsAltModeBinding) {
                ForEach(TerminalOptionAsAltMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Choose which physical Option key sends Alt to terminal apps. Other Option keys remain available for keyboard-layout characters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#endif
