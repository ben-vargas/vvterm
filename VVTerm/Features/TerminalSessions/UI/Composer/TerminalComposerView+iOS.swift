#if os(iOS)
import SwiftUI

struct TerminalComposerView: View {
    @ObservedObject var composer: TerminalComposerStore
    let isActive: Bool
    var acceptsInput = true
    var voice: TerminalComposerVoiceInput? = nil

    var body: some View {
        Group {
            if acceptsInput { content }
        }
        .onAppear(perform: stopUnavailableInput)
        .onChange(of: acceptsInput) { _ in stopUnavailableInput() }
    }

    private func stopUnavailableInput() {
        guard !acceptsInput else { return }
        composer.pickerPresented = false
        composer.cancel()
        if voice?.phase.isActive == true { voice?.cancel() }
    }

    private var content: some View {
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
                ZStack {
                    HStack(alignment: .bottom, spacing: 12) {
                        Button { composer.pickerPresented = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .regular))
                                .frame(width: 40, height: 40)
                        }
                        .accessibilityLabel("Attachments")
                        .accessibilityIdentifier("vvterm.composer.attach")
                        .adaptiveGlassCircle()
                        .disabled(composer.isBusy || !isActive)
                        .popover(isPresented: $composer.pickerPresented, arrowEdge: .bottom) {
                            TerminalAttachmentPicker(composer: composer)
                                .attachmentPopoverAdaptation()
                        }

                        HStack(alignment: .bottom, spacing: 4) {
                            TerminalComposerEditor(text: $composer.draft, isActive: isActive && !composer.isBusy,
                                                   acceptsEdits: voice?.phase.isActive != true) { images, urls in
                                composer.load { images + (try await TerminalAttachmentLoader.files(urls)) }
                            }
                            sendControl
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 2)
                        .adaptiveGlassRect(cornerRadius: 20)
                    }
                    .opacity(voice?.phase.isActive == true ? 0 : 1)
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
        .padding(.horizontal, 20)
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
        } else if composer.mode == .chat, !composer.canSend, let voice {
            Button(action: voice.toggle) {
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
