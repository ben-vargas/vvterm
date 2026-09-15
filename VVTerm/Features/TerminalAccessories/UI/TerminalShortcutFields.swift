import SwiftUI

struct TerminalShortcutFields: View {
    @Binding var key: TerminalAccessoryShortcutKey
    @Binding var modifiers: TerminalAccessoryShortcutModifiers

    var body: some View {
        Picker("Key", selection: $key) {
            ForEach(TerminalAccessoryShortcutKey.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Ctrl", isOn: $modifiers.control)
        Toggle("Alt", isOn: $modifiers.alternate)
        Toggle("Cmd", isOn: $modifiers.command)
        Toggle("Shift", isOn: $modifiers.shift)
    }
}
