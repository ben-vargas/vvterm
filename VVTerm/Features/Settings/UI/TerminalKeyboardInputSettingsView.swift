import SwiftUI

struct TerminalKeyboardInputSettingsView: View {
    #if os(iOS)
    @ObservedObject var voiceSettingsStore: VoiceSettingsStore
    #endif

    var body: some View {
        #if os(iOS)
        TerminalKeyboardInputPlatformSettingsView(
            voiceSettingsStore: voiceSettingsStore
        )
        .accessibilityIdentifier("vvterm.settings.page.keyboardAndInput")
        #else
        TerminalKeyboardInputPlatformSettingsView()
            .accessibilityIdentifier("vvterm.settings.page.keyboardAndInput")
        #endif
    }
}
