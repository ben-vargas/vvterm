nonisolated enum TerminalVoicePresentationState: Equatable, Sendable {
    nonisolated enum Event: Equatable, Sendable {
        case recordingStarted
        case recordingStopped
        case transcriptionSent
        case pendingReturnDismissed
        case systemActionSent(TerminalAccessorySystemActionID)
    }

    case idle
    case recording
    case pendingReturn

    var isRecording: Bool { self == .recording }
    var isPendingReturn: Bool { self == .pendingReturn }

    func applying(_ event: Event) -> Self {
        switch event {
        case .recordingStarted:
            return .recording
        case .recordingStopped:
            return self == .recording ? .idle : self
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
