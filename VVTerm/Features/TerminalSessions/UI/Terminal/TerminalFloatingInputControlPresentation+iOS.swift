#if os(iOS)
import SwiftUI

struct TerminalFloatingInputControlPresentation: Equatable {
    enum Intent: Equatable {
        case none
        case toggleVoice
        case cancelVoice
        case showKeyboard
        case sendReturn
        case system(TerminalAccessorySystemActionID)
    }

    enum Tint: Equatable {
        case none
        case accent
        case recording
        case secondary

        var color: Color? {
            switch self {
            case .none:
                nil
            case .accent:
                .accentColor
            case .recording:
                .red
            case .secondary:
                .secondary
            }
        }
    }

    let content: TerminalFloatingControlButton.Content
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let tint: Tint
    let isEnabled: Bool
    let isRepeatable: Bool
    let intent: Intent

    private init(
        content: TerminalFloatingControlButton.Content,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        tint: Tint,
        isEnabled: Bool,
        isRepeatable: Bool = false,
        intent: Intent
    ) {
        self.content = content
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.tint = tint
        self.isEnabled = isEnabled
        self.isRepeatable = isRepeatable
        self.intent = intent
    }

    var isInteractive: Bool {
        intent != .none
    }

    static func main(
        for phase: TerminalFloatingInputPhase,
        idleAction: TerminalFloatingControlPreferences.Action,
        terminalIsReady: Bool
    ) -> Self {
        switch phase {
        case .starting:
            Self(
                content: .systemImage("mic.fill"),
                accessibilityLabel: String(localized: "Starting voice input"),
                accessibilityIdentifier: "vvterm.terminal.floating.voiceProgress",
                tint: .recording,
                isEnabled: false,
                intent: .none
            )
        case .recording:
            Self(
                content: .systemImage("stop.fill"),
                accessibilityLabel: String(localized: "Stop and transcribe"),
                accessibilityIdentifier: "vvterm.terminal.floating.stopVoice",
                tint: .recording,
                isEnabled: true,
                intent: .toggleVoice
            )
        case .processing:
            Self(
                content: .systemImage("waveform"),
                accessibilityLabel: String(localized: "Transcribing audio"),
                accessibilityIdentifier: "vvterm.terminal.floating.voiceProgress",
                tint: .accent,
                isEnabled: false,
                intent: .none
            )
        case .pendingReturn:
            Self(
                content: .systemImage("arrow.turn.down.left"),
                accessibilityLabel: String(localized: "Send Return"),
                accessibilityIdentifier: "vvterm.terminal.floating.return",
                tint: .accent,
                isEnabled: terminalIsReady,
                intent: .sendReturn
            )
        case .idle:
            configured(
                idleAction,
                isPrimary: true,
                terminalIsReady: terminalIsReady
            )
        }
    }

    static func configured(
        _ action: TerminalFloatingControlPreferences.Action,
        isPrimary: Bool,
        terminalIsReady: Bool
    ) -> Self {
        let content = action.iconName.map(TerminalFloatingControlButton.Content.systemImage)
            ?? .text(action.shortTitle)
        let identifier: String
        let isEnabled: Bool
        let isRepeatable: Bool
        let intent: Intent

        switch action {
        case .voiceInput:
            identifier = "vvterm.terminal.floating.voiceInput"
            isEnabled = terminalIsReady
            isRepeatable = false
            intent = .toggleVoice
        case .keyboard:
            identifier = "vvterm.terminal.floating.keyboard"
            isEnabled = true
            isRepeatable = false
            intent = .showKeyboard
        case .system(let systemAction):
            identifier = "vvterm.terminal.floating.system.\(systemAction.rawValue)"
            isEnabled = terminalIsReady
            isRepeatable = systemAction.isRepeatable
            intent = .system(systemAction)
        }

        return Self(
            content: content,
            accessibilityLabel: action.displayTitle,
            accessibilityIdentifier: identifier,
            tint: isPrimary ? .accent : .none,
            isEnabled: isEnabled,
            isRepeatable: isRepeatable,
            intent: intent
        )
    }

    static var cancelVoice: Self {
        Self(
            content: .systemImage("xmark"),
            accessibilityLabel: String(localized: "Cancel voice input"),
            accessibilityIdentifier: "vvterm.terminal.floating.cancelVoice",
            tint: .secondary,
            isEnabled: true,
            intent: .cancelVoice
        )
    }
}
#endif
