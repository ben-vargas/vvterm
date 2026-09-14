#if os(iOS)
import SwiftUI

struct TerminalComposerView: View {
    @ObservedObject var composer: TerminalComposerStore
    let isActive: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !composer.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(composer.attachments) { attachment in
                            HStack {
                                Text(attachment.suggestedFilename).lineLimit(1)
                                Button { composer.removeAttachment(attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .accessibilityLabel(Text("Remove attachment") + Text(": \(attachment.suggestedFilename)"))
                                .accessibilityIdentifier("vvterm.attachment.remove.\(attachment.suggestedFilename)")
                                .disabled(composer.isBusy)
                            }
                            .padding(8)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        }
                    }
                }
            }
            if case .failed(let message) = composer.operation {
                Text(message).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("vvterm.composer.error")
            }
            if composer.mode == .chat {
                HStack(alignment: .bottom, spacing: 10) {
                    Button { composer.pickerPresented = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .regular))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Attachments")
                    .accessibilityIdentifier("vvterm.composer.attach")
                    .adaptiveGlassCircle()
                    .disabled(composer.isBusy || !isActive)

                    HStack(alignment: .bottom, spacing: 4) {
                        TerminalComposerEditor(text: $composer.draft, isActive: isActive && !composer.isBusy) { images, urls in
                            composer.load { images + (try await TerminalAttachmentLoader.files(urls)) }
                        }
                        .overlay(alignment: .topLeading) {
                            if composer.draft.isEmpty {
                                Text("Message")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 11)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        sendControl
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .adaptiveGlassRect(cornerRadius: 22)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Cancel") { composer.discardAttachments() }
                    sendControl
                }
            }
            if case .uploading(let filename) = composer.operation, !filename.isEmpty {
                Text(filename).font(.caption).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sendControl: some View {
        if composer.isBusy {
            Button { composer.cancel() } label: {
                ProgressView().frame(width: 36, height: 44)
            }
            .accessibilityLabel("Cancel")
        } else {
            Button { composer.send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(composer.canSend && isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel("Send")
            .accessibilityIdentifier("vvterm.composer.send")
            .disabled(!composer.canSend || !isActive)
        }
    }

}

struct TerminalPaneComposerView: View {
    @ObservedObject var presentationState: TerminalPresentationStateStore
    let composer: TerminalComposerStore
    let paneID: UUID
    let isActive: Bool

    var body: some View {
        TerminalComposerView(composer: composer, isActive: isActive && presentationState.terminalFindNavigatorVisibleByPane[paneID] != true)
    }
}

struct TerminalComposerMenuButton: View {
    @ObservedObject var composer: TerminalComposerStore
    @AppStorage(TerminalInputMode.preferenceKey) private var inputMode = TerminalInputMode.direct
    var body: some View {
        Button {
            inputMode = composer.mode == .direct ? .chat : .direct
            composer.setMode(inputMode)
        } label: {
            Label {
                if composer.mode == .direct { Text("Chat Mode") } else { Text("Normal Mode") }
            } icon: { Image(systemName: "text.bubble") }
        }
        .accessibilityIdentifier("vvterm.composer.toggle")
    }
}
#endif
