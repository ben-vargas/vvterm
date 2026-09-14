#if os(iOS)
import SwiftUI

struct TerminalComposerView: View {
    @ObservedObject var composer: TerminalComposerStore
    let isActive: Bool

    var body: some View {
        VStack(spacing: 8) {
            if composer.mode == .chat {
                HStack {
                    Text("Chat Mode").font(.headline)
                    Spacer()
                    Button("Close") { composer.setMode(.direct) }
                        .accessibilityIdentifier("vvterm.composer.close")
                }
                TerminalComposerEditor(text: $composer.draft, isActive: isActive && !composer.isBusy) { images, urls in
                    composer.load { images + (try await TerminalAttachmentLoader.files(urls)) }
                }
                .frame(height: 88)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
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
            HStack {
                if composer.mode == .chat {
                    Button { composer.pickerPresented = true } label: {
                        Label("Attachments", systemImage: "paperclip")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("vvterm.composer.attach")
                    .disabled(composer.isBusy)
                }
                if composer.isBusy {
                    ProgressView().accessibilityLabel("Uploading attachments")
                    if case .uploading(let filename) = composer.operation {
                        Text(filename).font(.caption).lineLimit(1)
                    }
                    Spacer()
                    Button("Cancel") { composer.cancel() }
                } else {
                    Spacer()
                    if composer.mode == .direct { Button("Cancel") { composer.discardAttachments() } }
                    Button("Send") { composer.send() }
                        .accessibilityIdentifier("vvterm.composer.send")
                        .disabled(!composer.canSend || !isActive)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
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
    var body: some View {
        Button { composer.setMode(composer.mode == .direct ? .chat : .direct) } label: {
            Label {
                if composer.mode == .direct { Text("Chat Mode") } else { Text("Direct Input") }
            } icon: { Image(systemName: "text.bubble") }
        }
        .accessibilityIdentifier("vvterm.composer.toggle")
    }
}
#endif
