#if os(iOS)
import SwiftUI

struct TerminalComposerView: View {
    @ObservedObject var composer: TerminalComposerStore
    let keyboard: TerminalKeyboardCoordinator
    let paneID: UUID
    let isActive: Bool
    let isKeyboardVisible: Bool
    var acceptsInput = true
    var voice: TerminalComposerVoiceInput? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var recordingTransition
    @State private var voiceInteraction = VoiceInteraction.text

    private enum VoiceInteraction { case text, ready }

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
        .onChange(of: voice != nil) { available in
            if !available { voiceInteraction = .text }
        }
        .onAppear(perform: stopUnavailableInput)
        .onChange(of: acceptsInput) { _ in stopUnavailableInput() }
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
            if composer.operation == .loading {
                ProgressView("Loading Files")
                    .font(.caption)
            }
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
                                        TerminalAttachmentPreview(attachment: attachment, isUploading: composer.isUploading(attachment)) {
                                            composer.removeAttachment(attachment.id)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 12)
                            .transition(.opacity)
                        }
                        HStack(alignment: .bottom, spacing: 4) {
                            editor
                            TerminalComposerSendButton(composer: composer, isActive: isActive && !isRecording)
                                .opacity(isRecording ? 0 : 1)
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
                    if voice != nil, composer.draft.isEmpty {
                        TerminalComposerVoiceControl(
                            onTap: { voiceInteraction = voiceInteraction == .ready ? .text : .ready },
                            onHold: startRecording
                        )
                        .frame(width: 40, height: 40)
                        .background {
                            Color.clear.adaptiveGlassCircle()
                                .matchedGeometryEffect(id: "voice", in: recordingTransition, isSource: !isRecording)
                        }
                        .disabled(!isActive || composer.isBusy || isRecording)
                        .opacity(isRecording ? 0 : 1)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: composer.draft.isEmpty)
                if let voice, isRecording {
                    recordingBar(voice)
                        .padding(.horizontal, 14)
                        .frame(height: 64)
                        .background {
                            Color.clear.adaptiveGlass()
                                .matchedGeometryEffect(id: "voice", in: recordingTransition)
                        }
                        .padding(.horizontal, -6)
                        .contextMenu { Button("Cancel voice input", action: voice.cancel) }
                        .accessibilityAction(named: Text("Cancel voice input"), voice.cancel)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, isKeyboardVisible ? 16 : 0)
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: voice?.phase)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: composer.attachments.map(\.id))
    }

    private var editor: some View {
        TerminalComposerEditor(
            text: $composer.draft,
            isActive: isActive && composer.attachmentSource == nil,
            keyboard: keyboard, paneID: paneID,
            acceptsEdits: voiceInteraction == .text && !isRecording,
            placeholder: voiceInteraction == .ready ? String(localized: "Touch and hold to record") : String(localized: "Type anything"),
            showsContent: !isRecording
        ) { images, urls in
            composer.load { images + (try await TerminalAttachmentLoader.files(urls)) }
        }
        .overlay {
            // A sibling control keeps UITextView selection gestures out of voice holds.
            TerminalComposerVoiceControl(style: .prompt, onTap: { voiceInteraction = .text }, onHold: startRecording)
                .allowsHitTesting(voiceInteraction != .text)
                .accessibilityHidden(voiceInteraction == .text)
        }
    }

    private func startRecording() {
        guard let voice, isActive, !composer.isBusy, !voice.phase.isActive else { return }
        voiceInteraction = .text
        voice.toggle()
    }

    private var attachmentButton: some View {
        TerminalAttachmentMenu { composer.attachmentSource = $0 }
            .frame(width: 40, height: 40)
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
    @ObservedObject var keyboard: TerminalKeyboardCoordinator
    let composer: TerminalComposerStore
    let paneID: UUID
    let isActive: Bool
    let acceptsInput: Bool
    let voice: TerminalComposerVoiceInput?
    var retainsInactiveInput = false

    var body: some View {
        TerminalComposerView(composer: composer, keyboard: keyboard, paneID: paneID, isActive: isActive,
                             isKeyboardVisible: keyboard.isSoftwareKeyboardVisible,
                             acceptsInput: acceptsInput && (retainsInactiveInput || keyboard.isComposerVisible(for: paneID)), voice: voice)
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
