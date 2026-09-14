import Foundation

/// View inputs derived from the tab's existing voice workflow.
struct TerminalComposerVoiceInput {
    let phase: VoiceRecordingOperationCoordinator.Phase
    let audioLevel: Float
    let duration: TimeInterval
    let toggle: () -> Void
    let cancel: () -> Void
}
