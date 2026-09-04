import XCTest
@testable import VVTerm

@MainActor
final class TerminalFloatingInputPhaseTests: XCTestCase {
    private let operationID = UUID()

    func testVoiceOperationPhaseTakesPriorityOverTerminalPresentation() {
        XCTAssertEqual(
            phase(.starting(operationID: operationID), presentation: .pendingReturn),
            .starting
        )
        XCTAssertEqual(
            phase(.recording(operationID: operationID), presentation: .idle),
            .recording
        )
        XCTAssertEqual(
            phase(.processing(operationID: operationID), presentation: .recording),
            .processing
        )
    }

    func testIdleOperationUsesTerminalPresentation() {
        XCTAssertEqual(phase(.idle, presentation: .idle), .idle)
        XCTAssertEqual(phase(.idle, presentation: .recording), .recording)
        XCTAssertEqual(phase(.idle, presentation: .pendingReturn), .pendingReturn)
    }

    func testPhaseCapabilitiesMatchInteractionRules() {
        XCTAssertFalse(TerminalFloatingInputPhase.idle.requiresVisibleControl)
        XCTAssertTrue(TerminalFloatingInputPhase.idle.allowsHiding)

        for phase in [
            TerminalFloatingInputPhase.starting,
            .recording,
            .processing,
        ] {
            XCTAssertTrue(phase.requiresVisibleControl)
            XCTAssertTrue(phase.showsVoiceStatus)
            XCTAssertFalse(phase.allowsHiding)
        }

        XCTAssertTrue(TerminalFloatingInputPhase.pendingReturn.requiresVisibleControl)
        XCTAssertFalse(TerminalFloatingInputPhase.pendingReturn.showsVoiceStatus)
        XCTAssertFalse(TerminalFloatingInputPhase.pendingReturn.allowsHiding)
    }

    private func phase(
        _ operationPhase: VoiceRecordingOperationCoordinator.Phase,
        presentation: TerminalVoicePresentationState
    ) -> TerminalFloatingInputPhase {
        TerminalFloatingInputPhase(
            voiceOperationPhase: operationPhase,
            voicePresentation: presentation
        )
    }
}
