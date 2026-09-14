#if os(iOS)
import SwiftUI

struct TerminalComposerView: View {
    @ObservedObject var composer: TerminalComposerStore
    let isActive: Bool
    var voice: TerminalComposerVoiceInput? = nil

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
                    Button {
                        if voice?.phase.isActive == true { voice?.cancel() }
                        else { composer.pickerPresented = true }
                    } label: {
                        Image(systemName: voice?.phase.isActive == true ? "xmark" : "plus")
                            .font(.system(size: 24, weight: .regular))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(voice?.phase.isActive == true ? String(localized: "Cancel voice input") : String(localized: "Attachments"))
                    .accessibilityIdentifier("vvterm.composer.attach")
                    .adaptiveGlassCircle()
                    .disabled(composer.isBusy || !isActive)

                    HStack(alignment: .bottom, spacing: 4) {
                        TerminalComposerEditor(text: $composer.draft, isActive: isActive && !composer.isBusy,
                                               acceptsEdits: voice?.phase.isActive != true) { images, urls in
                            composer.load { images + (try await TerminalAttachmentLoader.files(urls)) }
                        }
                        sendControl
                    }
                    .opacity(voice?.phase.isActive == true ? 0 : 1)
                    .allowsHitTesting(voice?.phase.isActive != true)
                    .accessibilityHidden(voice?.phase.isActive == true)
                    .overlay {
                        if let voice, voice.phase.isActive { recordingBar(voice) }
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
                ProgressView().frame(width: 44, height: 44)
            }
            .accessibilityLabel("Cancel")
        } else if composer.mode == .chat, !composer.canSend, let voice {
            Button(action: voice.toggle) {
                Image(systemName: "waveform")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Voice input")
            .accessibilityIdentifier("vvterm.composer.record")
            .disabled(!isActive)
        } else {
            Button { composer.send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(composer.canSend && isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Send")
            .accessibilityIdentifier("vvterm.composer.send")
            .disabled(!composer.canSend || !isActive)
        }
    }

    private func recordingBar(_ voice: TerminalComposerVoiceInput) -> some View {
        HStack(spacing: 10) {
            if case .recording = voice.phase {
                AnimatedWaveformView(audioLevel: voice.audioLevel, isRecording: true,
                                     width: 120, height: 22)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Text(Duration.seconds(max(0, voice.duration)).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                Button(action: voice.toggle) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Stop and transcribe")
                .accessibilityIdentifier("vvterm.composer.stop-recording")
            } else {
                ProgressView()
                Text(voice.phase.isProcessing ? String(localized: "Transcribing audio") : String(localized: "Starting voice input"))
                    .font(.callout)
                Spacer()
            }
        }
    }

}

struct TerminalPaneComposerView: View {
    @ObservedObject var presentationState: TerminalPresentationStateStore
    let composer: TerminalComposerStore
    let paneID: UUID
    let isActive: Bool
    let voice: TerminalComposerVoiceInput?

    var body: some View {
        TerminalComposerView(composer: composer, isActive: isActive && presentationState.terminalFindNavigatorVisibleByPane[paneID] != true, voice: voice)
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
