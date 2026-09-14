#if os(iOS)
import SwiftUI

struct TerminalComposerView: View {
    @ObservedObject var composer: TerminalComposerStore
    let isActive: Bool
    var acceptsInput = true
    var voice: TerminalComposerVoiceInput? = nil
    @State private var voiceInteraction = VoiceInteraction.text

    private enum VoiceInteraction { case text, ready, holding }

    var body: some View {
        Group {
            if acceptsInput { content }
        }
        .onAppear(perform: stopUnavailableInput)
        .onChange(of: acceptsInput) { _ in stopUnavailableInput() }
        .onChange(of: voice?.phase) { phase in
            if phase == .idle, voiceInteraction == .holding { voiceInteraction = .text }
        }
    }

    private func stopUnavailableInput() {
        guard !acceptsInput else { return }
        voiceInteraction = .text
        composer.attachmentSource = nil
        composer.cancel()
        if voice?.phase.isActive == true { voice?.cancel() }
    }

    private var content: some View {
        VStack(spacing: 8) {
            if !composer.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(composer.attachments) { attachment in
                            TerminalAttachmentPreview(attachment: attachment, isBusy: composer.isBusy) {
                                composer.removeAttachment(attachment.id)
                            }
                        }
                    }
                }
            }
            if case .failed(let message) = composer.operation {
                Text(message).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("vvterm.composer.error")
            }
            if composer.mode == .chat {
                ZStack {
                    HStack(alignment: .bottom, spacing: 12) {
                        Menu {
                            ForEach(TerminalComposerStore.AttachmentSource.allCases, id: \.self) { source in
                                Button { composer.attachmentSource = source } label: {
                                    Label(source.title, systemImage: source.symbol)
                                }
                                .accessibilityIdentifier(source.accessibilityIdentifier)
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .regular))
                                .frame(width: 40, height: 40)
                        }
                        .menuOrder(.fixed)
                        .accessibilityLabel("Attachments")
                        .accessibilityIdentifier("vvterm.composer.attach")
                        .background {
                            if composer.attachments.isEmpty { Color.clear.adaptiveGlassCircle() }
                        }
                        .disabled(composer.isBusy || !isActive)

                        HStack(alignment: .bottom, spacing: 4) {
                            TerminalComposerEditor(text: $composer.draft, isActive: isActive && !composer.isBusy,
                                                   acceptsEdits: voiceInteraction == .text && voice?.phase.isActive != true,
                                                   placeholder: voiceInteraction == .ready ? String(localized: "Touch and hold to record") : String(localized: "Message")) { images, urls in
                                composer.load { images + (try await TerminalAttachmentLoader.files(urls)) }
                            }
                            sendControl
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 2)
                        .background {
                            if composer.attachments.isEmpty { Color.clear.adaptiveGlassRect(cornerRadius: 20) }
                        }
                    }
                    // A mask keeps the native editor mounted and visible to the responder system.
                    .mask { Rectangle().fill(voice?.phase.isActive == true ? Color.clear : Color.black) }
                    .allowsHitTesting(voice?.phase.isActive != true)
                    .accessibilityHidden(voice?.phase.isActive == true)

                    if let voice, voice.phase.isActive {
                        recordingBar(voice)
                            .padding(.horizontal, 14)
                            .frame(height: 64)
                            .adaptiveGlass()
                            .padding(.horizontal, -6)
                            .contextMenu {
                                Button("Cancel voice input", action: voice.cancel)
                            }
                            .accessibilityAction(named: Text("Cancel voice input"), voice.cancel)
                    }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.25)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard voiceInteraction == .ready, isActive, !composer.isBusy,
                                  let voice, !voice.phase.isActive else { return }
                            if case .second(true, _) = value {
                                voiceInteraction = .holding
                                voice.toggle()
                            }
                        }
                        .onEnded { _ in
                            guard voiceInteraction == .holding, let voice else { return }
                            voiceInteraction = .text
                            switch voice.phase {
                            case .starting: voice.cancel()
                            case .recording: voice.toggle()
                            case .idle, .processing: break
                            }
                        }
                )
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
        .padding(composer.attachments.isEmpty ? 0 : 12)
        .background {
            if !composer.attachments.isEmpty { Color.clear.adaptiveGlassRect(cornerRadius: 28) }
        }
        .padding(.horizontal, composer.attachments.isEmpty ? 20 : 12)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sendControl: some View {
        if composer.isBusy {
            Button { composer.cancel() } label: {
                ProgressView().frame(width: 40, height: 40)
            }
            .accessibilityLabel("Cancel")
        } else if composer.mode == .chat, !composer.canSend, voice != nil {
            Button { voiceInteraction = voiceInteraction == .ready ? .text : .ready } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Voice input")
            .accessibilityIdentifier("vvterm.composer.record")
            .disabled(!isActive)
        } else {
            Button { composer.send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(composer.canSend && isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Send")
            .accessibilityIdentifier("vvterm.composer.send")
            .disabled(!composer.canSend || !isActive)
        }
    }

    private func recordingBar(_ voice: TerminalComposerVoiceInput) -> some View {
        HStack(spacing: 10) {
            if case .recording = voice.phase {
                GeometryReader { geometry in
                    AnimatedWaveformView(audioLevel: voice.audioLevel, isRecording: true,
                                         width: geometry.size.width, height: 22)
                }
                .frame(height: 22)
                .accessibilityHidden(true)
                Text(Duration.seconds(max(0, voice.duration)).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                Button(action: voice.toggle) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(width: 32, height: 32)
                        .background(.red.opacity(0.2), in: Circle())
                        .frame(width: 40, height: 40)
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
    let acceptsInput: Bool
    let voice: TerminalComposerVoiceInput?

    var body: some View {
        TerminalComposerView(composer: composer, isActive: isActive && presentationState.terminalFindNavigatorVisibleByPane[paneID] != true,
                             acceptsInput: acceptsInput, voice: voice)
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
