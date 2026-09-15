import XCTest
@testable import VVTerm

final class TerminalComposerSendActionsTests: XCTestCase {
    func testDefaultsAndNamedModifiedSequenceRoundTrip() throws {
        XCTAssertEqual(try TerminalComposerSendActions.load(Data()), .defaults)
        let action = TerminalComposerSendAction(name: "Queue", steps: [
            .key(.a, .init(control: true)), .insertDraft,
            .key(.tab, .init(shift: true)), .key(.enter, .none)
        ])
        let value = TerminalComposerSendActions(actions: [action, .insert])
        XCTAssertEqual(try TerminalComposerSendActions.load(value.encoded()), value)
        XCTAssertTrue(action.insertsDraft)
        XCTAssertFalse(TerminalComposerSendAction(steps: [.key(.enter, .none)]).insertsDraft)
    }

    func testTextAndDraftStepsRoundTripWithoutChangingOrder() throws {
        let action = TerminalComposerSendAction(steps: [.text("prefix\n"), .insertDraft, .text("suffix"), .key(.tab, .none)])
        let saved = TerminalComposerSendActions(actions: [action])
        XCTAssertEqual(try TerminalComposerSendActions.load(saved.encoded()), saved)
    }

    func testRepeatedStepsHaveStableDistinctIdentities() throws {
        var action = TerminalComposerSendAction(steps: [.key(.enter, .none), .key(.enter, .none)])
        let ids = action.steps.map(\.id)
        XCTAssertNotEqual(ids[0], ids[1])
        action.steps[0].input = .key(.tab, .init(shift: true))
        XCTAssertEqual(action.steps.map(\.id), ids)
        XCTAssertTrue(TerminalComposerSendActions(actions: [action]).isValid)
        action.steps[1] = action.steps[0]
        XCTAssertThrowsError(try TerminalComposerSendActions(actions: [action]).encoded())
    }

    func testRejectsInvalidSavedActionsInsteadOfChangingSendBehavior() throws {
        for value in [
            TerminalComposerSendActions(actions: []),
            TerminalComposerSendActions(actions: [.init(steps: [.text("")])]),
            TerminalComposerSendActions(actions: [.init(steps: [.text(String(repeating: "x", count: 2049))])]),
            TerminalComposerSendActions(actions: [.send, .send]),
            TerminalComposerSendActions(actions: [.init(steps: [])]),
            TerminalComposerSendActions(actions: [.init(steps: Array(repeating: .insertDraft, count: 65))]),
            TerminalComposerSendActions(actions: [.init(name: String(repeating: "x", count: 121), steps: [.insertDraft])])
        ] {
            XCTAssertThrowsError(try value.encoded())
            XCTAssertThrowsError(try TerminalComposerSendActions.load(JSONEncoder().encode(value)))
        }
        XCTAssertThrowsError(try TerminalComposerSendActions.load(Data("invalid".utf8)))
        XCTAssertThrowsError(try TerminalComposerSendActions.load(Data(repeating: 0, count: 1_048_577)))
    }
    #if os(iOS)
    @MainActor
    func testEverySupportedKeyMapsBeforeSubmission() throws {
        for key in TerminalAccessoryShortcutKey.allCases {
            let events = try XCTUnwrap(TerminalComposerSendAction.Step.key(key, .none).keyEvents())
            XCTAssertEqual(events.press.key.rawValue, key.rawValue)
            XCTAssertEqual(events.release.key, events.press.key)
            XCTAssertEqual(events.press.action, .press)
            XCTAssertEqual(events.release.action, .release)
        }
        XCTAssertNil(try TerminalComposerSendAction.Step.insertDraft.keyEvents())
        XCTAssertNil(try TerminalComposerSendAction.Step.text("prefix").keyEvents())
    }

    @MainActor
    func testModifiedKeysCarryModifiersWithoutLiteralText() throws {
        let step = TerminalComposerSendAction.Step.key(.c, .init(control: true, alternate: true, command: true, shift: true))
        let events = try XCTUnwrap(step.keyEvents())
        XCTAssertNil(events.press.text)
        XCTAssertEqual(events.press.unshiftedCodepoint, 99)
        XCTAssertEqual(events.press.mods, [.ctrl, .alt, .super, .shift])
        XCTAssertEqual(events.release.mods, events.press.mods)
        let shifted = try XCTUnwrap(TerminalComposerSendAction.Step.key(.a, .init(shift: true)).keyEvents())
        XCTAssertEqual(shifted.press.text, "A")
        XCTAssertEqual(shifted.press.unshiftedCodepoint, 97)
    }
    #endif

}
