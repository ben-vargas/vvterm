import Testing
@testable import VVTerm

struct TerminalVoicePresentationStateTests {
    @Test
    func recordingAndPendingReturnAreMutuallyExclusive() {
        let state = TerminalVoicePresentationState.recording
            .applying(.transcriptionSent)

        #expect(state == .pendingReturn)
        #expect(!state.isRecording)
        #expect(state.isPendingReturn)
    }

    @Test
    func lateRecordingStopDoesNotClearPendingReturn() {
        let state = TerminalVoicePresentationState.recording
            .applying(.transcriptionSent)
            .applying(.recordingStopped)

        #expect(state == .pendingReturn)
    }

    @Test
    func pendingReturnDismissalDoesNotStopRecording() {
        let state = TerminalVoicePresentationState.recording
            .applying(.pendingReturnDismissed)

        #expect(state == .recording)
    }

    @Test
    func recordingStopReturnsRecordingStateToIdle() {
        let state = TerminalVoicePresentationState.recording
            .applying(.recordingStopped)

        #expect(state == .idle)
    }

    @Test
    func editingActionsClearPendingReturnOnlyAfterTranscription() {
        let clearingActions: [TerminalAccessorySystemActionID] = [
            .enter,
            .escape,
            .backspace,
        ]

        for action in clearingActions {
            #expect(
                TerminalVoicePresentationState.pendingReturn
                    .applying(.systemActionSent(action)) == .idle
            )
            #expect(
                TerminalVoicePresentationState.recording
                    .applying(.systemActionSent(action)) == .recording
            )
        }

        #expect(
            TerminalVoicePresentationState.pendingReturn
                .applying(.systemActionSent(.tab)) == .pendingReturn
        )
    }
}
