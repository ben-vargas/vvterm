#if os(iOS)
import XCTest
@testable import VVTerm

@MainActor
final class TerminalFloatingInputControlPresentationTests: XCTestCase {
    func testVoicePhasesMapToMainButtonContent() {
        let idle = presentation(for: .idle)
        let starting = presentation(for: .starting)
        let recording = presentation(for: .recording)
        let processing = presentation(for: .processing)
        let pendingReturn = presentation(for: .pendingReturn)

        XCTAssertEqual(idle.content, .systemImage("mic.fill"))
        XCTAssertEqual(starting.content, .systemImage("mic.fill"))
        XCTAssertEqual(recording.content, .systemImage("stop.fill"))
        XCTAssertEqual(processing.content, .systemImage("waveform"))
        XCTAssertEqual(pendingReturn.content, .systemImage("arrow.turn.down.left"))

        XCTAssertEqual(recording.tint, .recording)
        XCTAssertEqual(pendingReturn.tint, .accent)
        XCTAssertFalse(starting.isInteractive)
        XCTAssertFalse(processing.isInteractive)
        XCTAssertTrue(recording.isInteractive)
        XCTAssertTrue(pendingReturn.isInteractive)
    }

    func testConfiguredPrimaryActionKeepsItsInteractionRules() {
        let primary = TerminalFloatingInputControlPresentation.configured(
            .system(.backspace),
            isPrimary: true,
            terminalIsReady: true
        )
        let secondary = TerminalFloatingInputControlPresentation.configured(
            .system(.backspace),
            isPrimary: false,
            terminalIsReady: true
        )

        XCTAssertEqual(primary.intent, .system(.backspace))
        XCTAssertTrue(primary.isRepeatable)
        XCTAssertEqual(primary.tint, .accent)
        XCTAssertEqual(secondary.tint, .none)
    }

    func testCancelActionUsesASeparateNeutralPresentation() {
        let cancel = TerminalFloatingInputControlPresentation.cancelVoice

        XCTAssertEqual(cancel.content, .systemImage("xmark"))
        XCTAssertEqual(cancel.intent, .cancelVoice)
        XCTAssertEqual(cancel.tint, .secondary)
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertTrue(cancel.isInteractive)
    }

    private func presentation(
        for phase: TerminalFloatingInputPhase
    ) -> TerminalFloatingInputControlPresentation {
        .main(
            for: phase,
            idleAction: .voiceInput,
            terminalIsReady: true
        )
    }
}
#endif
