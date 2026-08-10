import XCTest
@testable import VVTerm

final class ServerStatsErrorPresentationTests: XCTestCase {
    func testCollectionStateMapsCredentialApprovalMessage() {
        let request = ServerStatsApprovalRequest(
            id: "credential",
            serverID: UUID(),
            kind: .credentialEndpoint
        )
        let state = stateRequiringApproval(request)

        XCTAssertEqual(
            state.errorMessage,
            String(localized: "Credential endpoint approval is required.")
        )
    }

    func testCollectionStateMapsHostKeyApprovalMessage() {
        let request = ServerStatsApprovalRequest(
            id: "host-key",
            serverID: UUID(),
            kind: .hostKey
        )
        let state = stateRequiringApproval(request)

        XCTAssertEqual(
            state.errorMessage,
            String(localized: "SSH host key approval is required before authentication.")
        )
    }

    func testCollectionStatePassesThroughFailureMessage() {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()
        state.start(attemptID: attemptID)
        XCTAssertTrue(state.finish(attemptID: attemptID, errorMessage: "Connection failed"))

        XCTAssertEqual(state.errorMessage, "Connection failed")
    }

    func testCollectionStateHasNoMessageOutsideErrors() {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()
        XCTAssertNil(state.errorMessage)

        state.start(attemptID: attemptID)
        XCTAssertNil(state.errorMessage)

        XCTAssertTrue(state.markConnected(attemptID: attemptID))
        XCTAssertNil(state.errorMessage)

        state.stop()
        XCTAssertNil(state.errorMessage)
    }

    func testProcessControlErrorsMapExactMessages() {
        XCTAssertEqual(
            ProcessControlError.notConnected.localizedDescription,
            String(localized: "Stats is not connected to the server.")
        )
        XCTAssertEqual(
            ProcessControlError.protectedProcess.localizedDescription,
            String(localized: "This process cannot be killed from Stats.")
        )
    }

    private func stateRequiringApproval(
        _ request: ServerStatsApprovalRequest
    ) -> ServerStatsCollectionState {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()
        state.start(attemptID: attemptID)
        XCTAssertTrue(state.requireApproval(attemptID: attemptID, request: request))
        return state
    }
}
