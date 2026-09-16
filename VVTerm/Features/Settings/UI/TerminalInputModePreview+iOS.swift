#if os(iOS)
import SwiftUI

struct TerminalInputModePreview: View {
    let mode: TerminalInputMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "$ ssh server")
                    .foregroundStyle(.secondary)
                Text(verbatim: mode == .direct ? "server:~ $ ls -la ▏" : "server:~ $ ▏")
            }
            .font(.system(.caption, design: .monospaced))
            .padding(16)
            Spacer(minLength: 0)
            Group {
                switch mode {
                case .direct: accessoryPreview
                case .chat: composerPreview
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue(mode == .direct ? Text("Normal Mode") : Text("Chat Mode"))
        .accessibilityIdentifier("vvterm.settings.inputMode.preview")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
    }

    private var accessoryPreview: some View {
        HStack(spacing: 0) {
            ForEach(["esc", "ctrl", "alt", "tab"], id: \.self) { key in
                Text(verbatim: key).frame(maxWidth: .infinity)
            }
            Image(systemName: "paperclip").frame(maxWidth: .infinity)
            Image(systemName: "keyboard.chevron.compact.down").frame(maxWidth: .infinity)
        }
        .font(.system(size: 13, weight: .medium))
        .frame(height: 40)
        .adaptiveGlass()
    }

    private var composerPreview: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 16))
                .frame(width: 40, height: 40)
                .adaptiveGlass()
            HStack(spacing: 4) {
                Text(verbatim: "ls -la")
                    .font(.body)
                    .padding(.leading, 12)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 32)
                    .background(Color.accentColor, in: Capsule())
                    .frame(width: 48, height: 40)
            }
            .padding(.trailing, 2)
            .adaptiveGlassRect(cornerRadius: 20)
        }
    }
}
#endif
