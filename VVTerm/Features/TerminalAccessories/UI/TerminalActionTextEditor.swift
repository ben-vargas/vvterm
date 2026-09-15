import SwiftUI

struct TerminalActionTextEditor: View {
    @Binding var text: String
    var accessibilityID = "vvterm.custom-action.content"

    var body: some View {
        TextEditor(text: $text)
            .frame(minHeight: 120)
            .accessibilityIdentifier(accessibilityID)
    }
}
