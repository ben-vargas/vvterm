nonisolated enum TerminalVoicePresentationState: Equatable, Sendable {
    nonisolated enum RecordingStyle: Equatable, Sendable {
        case panel
        case floatingControl
    }

    nonisolated enum Event: Equatable, Sendable {
        case recordingStarted(RecordingStyle)
        case recordingStopped
        case transcriptionSent
        case pendingReturnDismissed
        case systemActionSent(TerminalAccessorySystemActionID)
    }

    case idle
    case recording(RecordingStyle)
    case pendingReturn

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
    var showsRecordingPanel: Bool { self == .recording(.panel) }
    var isPendingReturn: Bool { self == .pendingReturn }

    func applying(_ event: Event) -> Self {
        switch event {
        case .recordingStarted(let style):
            return .recording(style)
        case .recordingStopped:
            return isRecording ? .idle : self
        case .transcriptionSent:
            return .pendingReturn
        case .pendingReturnDismissed:
            return self == .pendingReturn ? .idle : self
        case .systemActionSent(let action):
            guard self == .pendingReturn else { return self }
            switch action {
            case .enter, .escape, .backspace:
                return .idle
            default:
                return self
            }
        }
    }
}
