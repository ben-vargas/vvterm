#if os(iOS)
import SwiftUI

struct TerminalKeyboardSettings: View {
    @AppStorage(TerminalKeyboardOptions.preferenceKey) private var storedOptions = 0

    var body: some View {
        Section {
            option("Auto-Correction", .autocorrection)
            option("Auto-Capitalization", .capitalization)
            option("Check Spelling", .spellChecking)
            if #available(iOS 17.0, *) { option("Inline Predictions", .inlinePrediction) }
            option("Smart Quotes and Dashes", .smartPunctuation)
            option("Smart Insert and Delete", .smartSpacing)
        } header: { Text("Keyboard") } footer: {
            Text("Off by default to keep terminal commands unchanged. Keyboard suggestions depend on your keyboard and system settings.")
        }
    }

    private func option(_ title: LocalizedStringKey, _ option: TerminalKeyboardOptions) -> some View {
        Toggle(title, isOn: Binding(get: {
            TerminalKeyboardOptions(rawValue: storedOptions).contains(option)
        }, set: { enabled in
            var options = TerminalKeyboardOptions(rawValue: storedOptions)
            if enabled { options.insert(option) } else { options.remove(option) }
            storedOptions = options.rawValue
        }))
        .accessibilityIdentifier("vvterm.composer.keyboard-option.\(option.rawValue)")
    }
}
#endif
