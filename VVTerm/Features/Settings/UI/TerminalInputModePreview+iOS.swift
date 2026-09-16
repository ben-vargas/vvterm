#if os(iOS)
import SwiftUI

struct TerminalInputModePreview: View {
    let mode: TerminalInputMode
    let showsChatAccessory: Bool
    @FocusState private var isDraftFocused: Bool
    @State private var draft = "ls -la"
    @State private var output = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "$ ssh server")
                    .foregroundStyle(.secondary)
                Text(verbatim: output.isEmpty ? "server:~ $ ▏" : output)
                    .lineLimit(2)
                    .accessibilityIdentifier("vvterm.settings.inputMode.preview.output")
            }
            .font(.system(.caption, design: .monospaced))
            .padding(16)
            Spacer(minLength: 0)
            Group {
                switch mode {
                case .direct: accessoryPreview
                case .chat:
                    VStack(spacing: 8) {
                        if showsChatAccessory {
                            TerminalComposerAccessoryView(
                                snapshot: .init(profile: .defaultValue(lastWriterDeviceId: "input-mode-preview"),
                                                showsDismissKeyboardButton: false, showsAttachmentButton: false),
                                onKey: showKey, onCustomAction: { output = $0.title }
                            )
                            .frame(height: 40)
                            .padding(.horizontal, -12)
                        }
                        composerPreview
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, minHeight: 236, maxHeight: 236)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
        .accessibilityValue(mode == .direct ? Text("Normal Mode") : Text("Chat Mode"))
        .accessibilityIdentifier("vvterm.settings.inputMode.preview")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
        .onChange(of: mode) { _ in isDraftFocused = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isDraftFocused = false }
                    .accessibilityIdentifier("vvterm.settings.inputMode.preview.done")
            }
        }
    }

    private var accessoryPreview: some View {
        NormalAccessoryPreview(onKey: showKey, onDismiss: { output = String(localized: "Hide keyboard") })
            .frame(height: 48)
    }

    private func showKey(_ key: TerminalKey) {
        if case .modified(let base, let modifiers) = key {
            let names = TerminalAccessoryShortcutModifiers(
                control: modifiers.contains(.ctrl), alternate: modifiers.contains(.alt),
                command: modifiers.contains(.super), shift: modifiers.contains(.shift)
            )
            output = names.displayTitle(for: keyTitle(base))
        } else {
            output = keyTitle(key)
        }
    }

    private func keyTitle(_ key: TerminalKey) -> String {
        TerminalAccessorySystemActionID.allCases.first {
            $0.terminalKey?.ansiSequence == key.ansiSequence
        }?.listTitle ?? ""
    }

    private var composerPreview: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 16))
                .frame(width: 40, height: 40)
                .adaptiveGlass()
            HStack(spacing: 4) {
                TextField("Type anything", text: $draft)
                    .focused($isDraftFocused)
                    .submitLabel(.done)
                    .onSubmit { isDraftFocused = false }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("vvterm.settings.inputMode.preview.draft")
                    .font(.body)
                    .padding(.leading, 12)
                Spacer(minLength: 0)
                Button {
                    output = "server:~ $ " + draft
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 28)
                    .background(Color.accentColor, in: Capsule())
                    .frame(width: 48, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("vvterm.settings.inputMode.preview.send")
            }
            .padding(.trailing, 2)
            .adaptiveGlassRect(cornerRadius: 20)
        }
    }
}
/// Uses the production Normal bar with local callbacks and no terminal runtime.
private struct NormalAccessoryPreview: UIViewRepresentable {
    let onKey: (TerminalKey) -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> TerminalInputAccessoryView {
        TerminalInputAccessoryView(
            terminalOwner: nil,
            inputSnapshot: .init(profile: .defaultValue(lastWriterDeviceId: "input-mode-preview"),
                                 showsDismissKeyboardButton: true, showsAttachmentButton: false),
            onKey: onKey, onCustomAction: { _ in }, onDismissKeyboard: onDismiss
        )
    }

    func updateUIView(_ view: TerminalInputAccessoryView, context: Context) {}
}
#endif
