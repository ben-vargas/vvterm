#if os(iOS)
import SwiftUI

struct TerminalComposerView: View {
    @ObservedObject var composer: TerminalComposerStore
    let isActive: Bool
    var acceptsInput = true
    var voice: TerminalComposerVoiceInput? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var voiceInteraction = VoiceInteraction.text

    private enum VoiceInteraction { case text, ready, holding }

    var body: some View {
        Group {
            if acceptsInput { content }
        }
        .alert("Could not remove remote attachments.", isPresented: Binding(
            get: { composer.cleanupError != nil },
            set: { if !$0 { composer.dismissCleanupError() } }
        )) {
            Button("OK") { composer.dismissCleanupError() }
        } message: { Text(composer.cleanupError ?? "") }
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

    private var isRecording: Bool { voice?.phase.isActive == true }

    private var content: some View {
        VStack(spacing: 8) {
            if case .failed(let message) = composer.operation {
                Text(message).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("vvterm.composer.error")
            }
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 12) {
                    attachmentButton
                        .opacity(isRecording ? 0 : 1)
                        .disabled(isRecording || composer.isBusy || !isActive)
                    VStack(alignment: .leading, spacing: 8) {
                        if !composer.attachments.isEmpty {
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(composer.attachments) { attachment in
                                        TerminalAttachmentPreview(attachment: attachment) {
                                            composer.removeAttachment(attachment.id)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 12)
                            .transition(.opacity)
                        }
                        HStack(alignment: .bottom, spacing: 4) {
                            TerminalComposerEditor(
                                text: $composer.draft,
                                isActive: isActive && composer.attachmentSource == nil,
                                acceptsEdits: voiceInteraction == .text && !isRecording,
                                placeholder: voiceInteraction == .ready ? String(localized: "Touch and hold to record") : String(localized: "Message"),
                                showsContent: !isRecording,
                                onPromptTap: voiceInteraction == .ready ? { voiceInteraction = .text } : nil
                            ) { images, urls in
                                composer.load { images + (try await TerminalAttachmentLoader.files(urls)) }
                            }
                            .simultaneousGesture(recordingGesture)
                            sendControl.opacity(isRecording ? 0 : 1)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, composer.attachments.isEmpty ? 2 : 12)
                    .padding(.bottom, composer.attachments.isEmpty ? 0 : 8)
                    .background {
                        Color.clear
                            .adaptiveGlassRect(cornerRadius: composer.attachments.isEmpty ? 20 : 28)
                            .opacity(isRecording ? 0 : 1)
                    }
                }
                if let voice, isRecording {
                    recordingBar(voice)
                        .padding(.horizontal, 14)
                        .frame(height: 64)
                        .adaptiveGlass()
                        .padding(.horizontal, -6)
                        .contextMenu { Button("Cancel voice input", action: voice.cancel) }
                        .accessibilityAction(named: Text("Cancel voice input"), voice.cancel)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: voice?.phase)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: composer.attachments.map(\.id))
    }

    private var recordingGesture: some Gesture {
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
    }

    private var attachmentButton: some View {
        TerminalAttachmentMenu { composer.attachmentSource = $0 }
            .frame(width: 40, height: 40)
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
