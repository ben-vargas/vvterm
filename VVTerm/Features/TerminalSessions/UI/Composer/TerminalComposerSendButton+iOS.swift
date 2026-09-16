#if os(iOS)
import SwiftUI

struct TerminalComposerSendButton: View {
    @ObservedObject var composer: TerminalComposerStore
    let isActive: Bool
    @AppStorage(TerminalComposerSendActions.preferenceKey) private var storedActions = Data()

    @State private var showsReadError = false

    var body: some View {
        switch Result(catching: { try TerminalComposerSendActions.load(storedActions) }) {
        case .success(let configuration):
            Menu {
                ForEach(configuration.actions) { action in
                    Button(action.title) { composer.send(action: action) }
                        .accessibilityIdentifier("vvterm.composer.action.\(action.id)")
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 32)
                    .background(composer.canSend && isActive ? Color.accentColor : Color.secondary, in: Capsule())
                    .frame(width: 48, height: 40)
            } primaryAction: {
                if let action = configuration.actions.first { composer.send(action: action) }
            }
            .accessibilityLabel("Send")
            .accessibilityValue(configuration.actions.first?.title ?? "")
            .accessibilityHint("Touch and hold for send actions.")
            .accessibilityIdentifier("vvterm.composer.send")
            .disabled(!composer.canSend || !isActive)
        case .failure:
            Button { showsReadError = true } label: {
                Image(systemName: "exclamationmark.circle").frame(width: 48, height: 40)
            }
            .accessibilityLabel("Could not read send actions. Reset them in Input Mode settings.")
            .alert("Could not read send actions. Reset them in Input Mode settings.", isPresented: $showsReadError) {
                Button("OK") {}
            }
        }
    }
}
#endif
