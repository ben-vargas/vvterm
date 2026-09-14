#if os(iOS) && DEBUG
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class TerminalComposerUITestModel: ObservableObject {
    let paneID = UUID()
    let keyboard: TerminalKeyboardCoordinator
    @Published var terminal: GhosttyTerminalView?
    @Published var sent = ""
    @Published var received = ""
    @Published var failUpload = false
    @Published var attachmentButtonEnabled = true
    @Published var connected = true
    @Published var voicePhase = VoiceRecordingOperationCoordinator.Phase.idle

    lazy var composer: TerminalComposerStore = makeComposer()

    private func makeComposer() -> TerminalComposerStore {
        TerminalComposerStore(resolveRoute: { [weak self] in
        guard let self, self.connected else { throw TerminalAttachmentError.unavailable }
        return TerminalAttachmentRoute(upload: { [weak self] attachment in
            try await Task.sleep(for: .milliseconds(100))
            if self?.failUpload == true { throw TerminalAttachmentError.unreadable }
            return RemoteClipboardUpload(remotePath: "/tmp/\(attachment.suggestedFilename)",
                                         pastedPathToken: "/tmp/\(attachment.suggestedFilename)",
                                         mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes)
        }, remove: { _ in }, submit: { [weak self] text, mode in
            guard let self, self.keyboard.canSubmitComposedInput(for: self.paneID), let terminal = self.terminal else {
                throw TerminalAttachmentError.unavailable
            }
            try terminal.sendComposedText(text, mode: mode)
            self.sent = text
        })
    }, modeChanged: { [weak self] _ in
        guard let self else { return }
        self.keyboard.composerModeDidChange(for: self.paneID)
    })

    }

    init(keyboard: TerminalKeyboardCoordinator) { self.keyboard = keyboard }

    func attach(_ terminal: GhosttyTerminalView) {
        self.terminal = terminal
        keyboard.terminalProvider = { [weak self] id in
            guard let self, id == self.paneID else { return nil }
            return self.terminal
        }
        keyboard.inputModeProvider = { [weak self] _ in self?.composer.mode ?? .direct }
        terminal.setLifecycleCallbacks(.init(windowAttachmentChanged: { [weak self] attached in
            guard let self else { return }
            self.keyboard.setWindowAttached(attached, for: self.paneID)
        }, directTouch: { _ in }, keyboardAccessoryHideRequested: {}, findNavigatorVisibilityChanged: { [weak self] active in
            guard let self else { return }
            self.keyboard.setFindNavigatorActive(active, for: self.paneID)
        }))
        terminal.writeCallback = { [weak self] data in
            DispatchQueue.main.async { self?.received += String(decoding: data, as: UTF8.self) }
        }
        terminal.setupWriteCallback()
        terminal.showsVoiceAccessoryButton = true
        terminal.onVoiceButtonTapped = { _ in }
        terminal.onAttachmentButtonTapped = { [weak self] in self?.composer.pickerPresented = true }
        keyboard.setWindowAttached(terminal.window != nil, for: paneID)
        keyboard.setActivePane(paneID)
        keyboard.setPaneInputEligible(true, for: paneID)
        keyboard.setViewActive(true)
    }

    func addFixtures() {
        composer.load {
            [TerminalAttachmentPayload(data: Data([1]), contentType: .png, suggestedFilename: "one.png"),
             TerminalAttachmentPayload(data: Data([2]), contentType: .pdf, suggestedFilename: "two.pdf")]
        }
    }
}

struct TerminalComposerUITestHarness: View {
    @EnvironmentObject private var runtime: GhosttyRuntime
    @StateObject private var model: TerminalComposerUITestModel

    init(keyboard: TerminalKeyboardCoordinator) {
        _model = StateObject(wrappedValue: TerminalComposerUITestModel(keyboard: keyboard))
    }

    var body: some View {
        TerminalComposerUITestContent(model: model, composer: model.composer, runtime: runtime)
            .task { runtime.startIfNeeded() }
    }
}

private struct TerminalComposerUITestContent: View {
    @ObservedObject var model: TerminalComposerUITestModel
    @ObservedObject var composer: TerminalComposerStore
    @ObservedObject var runtime: GhosttyRuntime
    @AppStorage(TerminalInputMode.preferenceKey) private var inputMode = TerminalInputMode.direct
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                TerminalComposerMenuButton(composer: composer)
                Button("Add fixtures") { model.addFixtures() }.accessibilityIdentifier("composer.test.add")
                Button("Settings") { showsSettings = true }.accessibilityIdentifier("composer.test.settings")
                Button("Find") { model.terminal?.showFindNavigator() }
            }
            HStack {
                Button(model.failUpload ? "Uploads fail" : "Uploads succeed") { model.failUpload.toggle() }
                    .accessibilityIdentifier("composer.test.fail")
                Toggle("Attachment button", isOn: $model.attachmentButtonEnabled).accessibilityIdentifier("composer.test.visibility")
            }
            HStack {
                Button("Disconnect") {
                    model.connected = false
                    model.keyboard.setPaneInputEligible(false, for: model.paneID)
                }
                Button("Reconnect") {
                    model.connected = true
                    model.keyboard.setPaneInputEligible(true, for: model.paneID)
                }
            }
            Text(model.sent.isEmpty ? "No input sent" : model.sent)
                .accessibilityIdentifier("composer.test.sent")
                .font(.caption)
            Text(model.received.replacingOccurrences(of: "\r", with: "<CR>").replacingOccurrences(of: "\n", with: "<LF>"))
                .accessibilityIdentifier("composer.test.bytes")
                .font(.caption)
            if runtime.app != nil {
                ComposerTestSurface(model: model, runtime: runtime)
                    .frame(minHeight: 70, maxHeight: .infinity)
            }
            if composer.mode == .chat || composer.isBusy || !composer.attachments.isEmpty {
                TerminalComposerView(composer: composer, isActive: true, voice: .init(
                    phase: model.voicePhase, audioLevel: 0.4, duration: 2,
                    toggle: {
                        if model.voicePhase.isActive {
                            model.voicePhase = .idle
                            composer.appendTranscription("Voice draft")
                        } else { model.voicePhase = .recording(operationID: UUID()) }
                    },
                    cancel: { model.voicePhase = .idle }
                ))
            }
        }
        .terminalKeyboardAvoidance(
            focusedPaneId: model.paneID,
            paneIds: [model.paneID],
            terminalSurfaceChange: nil,
            terminalProvider: { _ in model.terminal },
            keyboardCoordinator: model.keyboard,
            scope: .container
        )
        .onAppear { inputMode = .direct; composer.setMode(.direct) }
        .onChange(of: inputMode) { composer.setMode($0) }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                Form { TerminalInputModePicker() }
                    .toolbar { Button("Done") { showsSettings = false } }
            }
        }
        .sheet(isPresented: $composer.pickerPresented) { TerminalAttachmentPicker(composer: composer) }
    }
}

private struct ComposerTestSurface: UIViewRepresentable {
    @ObservedObject var model: TerminalComposerUITestModel
    let runtime: GhosttyRuntime

    func makeUIView(context: Context) -> GhosttyTerminalView {
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 220), worktreePath: NSHomeDirectory(),
            ghosttyApp: runtime.app!, appWrapper: runtime, paneId: model.paneID.uuidString,
            terminalAccessoryInputSnapshot: snapshot, useCustomIO: true
        )
        terminal.acceptsTerminalInput = true
        terminal.keyboardUITestSetHardwareKeyboardAttached(false)
        terminal.onReady = { [weak terminal, weak model] in
            guard let terminal, let model else { return }
            model.attach(terminal)
        }
        return terminal
    }

    func updateUIView(_ terminal: GhosttyTerminalView, context: Context) {
        terminal.applyTerminalAccessoryInputSnapshot(snapshot)
    }

    private var snapshot: TerminalAccessoryInputSnapshot {
        .init(profile: .defaultValue(lastWriterDeviceId: "composer-ui-test"), showsDismissKeyboardButton: true,
              showsAttachmentButton: model.attachmentButtonEnabled)
    }
}
#endif
