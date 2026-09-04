#if os(iOS)
import SwiftUI

struct TerminalFloatingVoiceStatus: View {
    let phase: TerminalFloatingInputPhase
    @ObservedObject var audioService: AudioService

    private var title: String {
        switch phase {
        case .processing:
            String(localized: "Processing")
        case .recording:
            String(localized: "Listening…")
        case .starting:
            String(localized: "Starting voice input")
        case .idle, .pendingReturn:
            ""
        }
    }

    private var detail: String {
        if phase == .processing {
            return String(localized: "Transcribing audio")
        }
        let transcript = audioService.transcribedText.isEmpty
            ? audioService.partialTranscription
            : audioService.transcribedText
        return transcript.isEmpty ? String(localized: "Speak now…") : transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if phase == .recording {
                    PulsingRecordingIndicator()
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.accentColor)
                }

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(phase == .recording ? Color.red : Color.primary)
            }

            Text(detail)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .modifier(FloatingVoiceStatusSurface(isRecording: phase == .recording))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("vvterm.terminal.floating.voiceStatus")
    }
}

private struct FloatingVoiceStatusSurface: ViewModifier {
    let isRecording: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(
                .regular.tint((isRecording ? Color.red : Color.accentColor).opacity(0.08)),
                in: shape
            )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(
                        (isRecording ? Color.red : Color.accentColor).opacity(0.22),
                        lineWidth: 1
                    )
                }
        }
    }
}
#endif
