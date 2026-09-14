#if os(iOS)
import SwiftUI

struct TerminalInputModePicker: View {
    @AppStorage(TerminalInputMode.preferenceKey) private var inputMode = TerminalInputMode.direct

    var body: some View {
        Picker("Input Mode", selection: $inputMode) {
            Text("Normal Mode").tag(TerminalInputMode.direct)
            Text("Chat Mode").tag(TerminalInputMode.chat)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("vvterm.input-mode")
    }
}
#endif
