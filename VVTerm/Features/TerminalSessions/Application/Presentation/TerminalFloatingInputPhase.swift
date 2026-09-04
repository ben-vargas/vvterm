import Foundation

nonisolated enum TerminalFloatingInputPhase: Equatable, Sendable {
    case idle
    case starting
    case recording
    case processing
    case pendingReturn

    @MainActor
    init(
        voiceOperationPhase: VoiceRecordingOperationCoordinator.Phase,
        voicePresentation: TerminalVoicePresentationState
    ) {
        switch voiceOperationPhase {
        case .starting:
            self = .starting
        case .recording:
            self = .recording
        case .processing:
            self = .processing
        case .idle:
            switch voicePresentation {
            case .idle:
                self = .idle
            case .recording:
                self = .recording
            case .pendingReturn:
                self = .pendingReturn
            }
        }
    }

    var requiresVisibleControl: Bool {
        self != .idle
    }

    var showsVoiceStatus: Bool {
        switch self {
        case .starting, .recording, .processing:
            true
        case .idle, .pendingReturn:
            false
        }
    }

    var allowsHiding: Bool {
        self == .idle
    }
}
