import SwiftUI

struct RemoteShellStartupActionSection: View {
    @Binding var model: RemoteShellStartupActionFormModel
    let remoteSessionEnabled: Bool

    var body: some View {
        Section {
            TextField(
                "Command",
                text: $model.command,
                prompt: Text(verbatim: exampleCommand),
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif

            if let validationError = model.validationError {
                Text(message(for: validationError))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Startup Command")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: LocalizedStringKey {
        remoteSessionEnabled
            ? "Syncs across devices. Runs only when VVTerm creates a persistent session. Do not include secrets."
            : "Syncs across devices. Runs for each new terminal connection. Do not include secrets."
    }

    private var exampleCommand: String {
        remoteSessionEnabled
            ? "cd ~/myproject && exec $SHELL -l"
            : "cd ~/myproject && exec tmux attach"
    }

    private func message(
        for error: RemoteShellStartupActionFormModel.ValidationError
    ) -> String {
        switch error {
        case .invalidCommand:
            String(localized: "The command contains unsupported control characters.")
        case .commandTooLong:
            String(
                format: String(localized: "The command must be %lld UTF-8 bytes or less."),
                Int64(RemoteShellStartupAction.maximumCommandByteCount)
            )
        }
    }
}
