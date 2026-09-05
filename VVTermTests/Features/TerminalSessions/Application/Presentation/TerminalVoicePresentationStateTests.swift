import Testing
@testable import VVTerm

struct TerminalVoicePresentationStateTests {
    @Test
    func keyboardRecordingKeepsItsPanelUntilStopped() {
        let state = TerminalVoicePresentationState.idle.applying(.recordingStarted(.panel))
        #expect(state.isRecording)
        #expect(state.showsRecordingPanel)
        #expect(state.applying(.pendingReturnDismissed) == state)
        #expect(state.applying(.recordingStopped) == .idle)
        #expect(state.applying(.transcriptionSent) == .pendingReturn)
        #expect(!TerminalVoicePresentationState.recording(.floatingControl).showsRecordingPanel)
    }

    @Test
    func recordingAndPendingReturnAreMutuallyExclusive() {
        let state = TerminalVoicePresentationState.recording(.floatingControl)
            .applying(.transcriptionSent)

        #expect(state == .pendingReturn)
        #expect(!state.isRecording)
        #expect(state.isPendingReturn)
    }

    @Test
    func lateRecordingStopDoesNotClearPendingReturn() {
        let state = TerminalVoicePresentationState.recording(.floatingControl)
            .applying(.transcriptionSent)
            .applying(.recordingStopped)

        #expect(state == .pendingReturn)
    }

    @Test
    func pendingReturnDismissalDoesNotStopRecording() {
        let state = TerminalVoicePresentationState.recording(.floatingControl)
            .applying(.pendingReturnDismissed)

        #expect(state == .recording(.floatingControl))
    }

    @Test
    func recordingStopReturnsRecordingStateToIdle() {
        let state = TerminalVoicePresentationState.recording(.floatingControl)
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
                TerminalVoicePresentationState.recording(.floatingControl)
                    .applying(.systemActionSent(action)) == .recording(.floatingControl)
            )
        }

        #expect(
            TerminalVoicePresentationState.pendingReturn
                .applying(.systemActionSent(.tab)) == .pendingReturn
        )
    }
}
