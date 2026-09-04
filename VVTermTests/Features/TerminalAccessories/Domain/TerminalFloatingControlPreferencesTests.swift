import XCTest
@testable import VVTerm

final class TerminalFloatingControlPreferencesTests: XCTestCase {
    func testDefaultsMatchProductContract() {
        let preferences = TerminalFloatingControlPreferences.defaultValue

        XCTAssertEqual(preferences.style, .compact)
        XCTAssertEqual(
            preferences.compactActionLayout,
            .init(
                primaryAction: .voiceInput,
                secondaryActions: [.system(.backspace), .system(.escape), .keyboard]
            )
        )
        XCTAssertEqual(
            preferences.radialActionLayout,
            .init(
                primaryAction: .voiceInput,
                secondaryActions: [.system(.backspace), .system(.escape), .keyboard]
            )
        )
        XCTAssertNil(preferences.hiddenSide)
        XCTAssertEqual(preferences.horizontalFraction, 1)
        XCTAssertEqual(preferences.verticalFraction, 1)
    }

    func testNormalizationKeepsPerStyleOrderAndValidUniqueActions() {
        let preferences = TerminalFloatingControlPreferences(
            compactActionLayout: .init(
                primaryAction: .system(.commandModifier),
                secondaryActions: [
                    .keyboard,
                    .keyboard,
                    .system(.unknown),
                    .system(.escape),
                    .system(.tab),
                    .system(.backspace),
                ]
            ),
            radialActionLayout: .init(
                primaryAction: .system(.backspace),
                secondaryActions: [
                    .voiceInput,
                    .system(.backspace),
                    .keyboard,
                    .system(.escape),
                    .system(.tab),
                    .system(.arrowUp),
                    .system(.arrowDown),
                    .system(.arrowLeft),
                    .system(.arrowRight),
                ]
            ),
            horizontalFraction: -2.5,
            verticalFraction: 2.5
        ).normalized()

        XCTAssertEqual(
            preferences.compactActionLayout,
            .init(
                primaryAction: .voiceInput,
                secondaryActions: [.keyboard, .system(.escape), .system(.tab)]
            )
        )
        XCTAssertEqual(
            preferences.radialActionLayout,
            .init(
                primaryAction: .system(.backspace),
                secondaryActions: [
                    .voiceInput,
                    .keyboard,
                    .system(.escape),
                    .system(.tab),
                    .system(.arrowUp),
                    .system(.arrowDown),
                    .system(.arrowLeft),
                ]
            )
        )
        XCTAssertEqual(preferences.horizontalFraction, 0)
        XCTAssertEqual(preferences.verticalFraction, 1)
    }

    func testNormalizationRepairsNonFinitePositionAndPreservesHiddenSide() {
        let preferences = TerminalFloatingControlPreferences(
            hiddenSide: .left,
            horizontalFraction: .nan,
            verticalFraction: .infinity
        ).normalized()

        XCTAssertEqual(preferences.hiddenSide, .left)
        XCTAssertEqual(
            preferences.horizontalFraction,
            TerminalFloatingControlPreferences.defaultHorizontalFraction
        )
        XCTAssertEqual(
            preferences.verticalFraction,
            TerminalFloatingControlPreferences.defaultVerticalFraction
        )
    }

    func testStylesKeepIndependentActionLayouts() {
        let preferences = TerminalFloatingControlPreferences(
            compactActionLayout: .init(
                primaryAction: .keyboard,
                secondaryActions: [.system(.escape)]
            ),
            radialActionLayout: .init(
                primaryAction: .system(.backspace),
                secondaryActions: [.voiceInput, .keyboard, .system(.tab)]
            )
        )

        XCTAssertEqual(
            preferences.actionLayout(for: .compact),
            .init(primaryAction: .keyboard, secondaryActions: [.system(.escape)])
        )
        XCTAssertEqual(
            preferences.actionLayout(for: .radial),
            .init(
                primaryAction: .system(.backspace),
                secondaryActions: [.voiceInput, .keyboard, .system(.tab)]
            )
        )
        XCTAssertNil(preferences.actionLayout(for: .off))
    }

    func testVoicePrimaryFallsBackToKeyboardWithoutChangingSavedLayout() {
        let preferences = TerminalFloatingControlPreferences(
            radialActionLayout: .init(
                primaryAction: .voiceInput,
                secondaryActions: [.keyboard, .system(.escape)]
            )
        )

        XCTAssertEqual(
            preferences.resolvedActionLayout(
                for: .radial,
                hasProAccess: true,
                voiceEnabled: false
            ),
            .init(primaryAction: .keyboard, secondaryActions: [.system(.escape)])
        )
        XCTAssertEqual(preferences.radialActionLayout.primaryAction, .voiceInput)
    }

    func testFreeAccessUsesDefaultCompactLayoutWithoutChangingSavedLayouts() {
        let preferences = TerminalFloatingControlPreferences(
            style: .radial,
            compactActionLayout: .init(
                primaryAction: .system(.escape),
                secondaryActions: [.keyboard, .voiceInput]
            ),
            radialActionLayout: .init(
                primaryAction: .system(.tab),
                secondaryActions: [.system(.backspace)]
            )
        )

        XCTAssertEqual(preferences.activeStyle(hasProAccess: false), .compact)
        XCTAssertEqual(
            preferences.resolvedActionLayout(
                for: .compact,
                hasProAccess: false,
                voiceEnabled: true
            ),
            TerminalFloatingControlPreferences.defaultCompactActionLayout
        )
        XCTAssertEqual(preferences.radialActionLayout.primaryAction, .system(.tab))
    }

    func testOffHasNoActiveStyle() {
        let preferences = TerminalFloatingControlPreferences(style: .off)

        XCTAssertNil(preferences.activeStyle(hasProAccess: false))
        XCTAssertNil(preferences.activeStyle(hasProAccess: true))
    }

    func testStyleLimitsAndActionListAreExplicit() {
        XCTAssertEqual(TerminalFloatingControlPreferences.Style.off.maximumSecondaryActionCount, 0)
        XCTAssertEqual(
            TerminalFloatingControlPreferences.Style.compact.maximumSecondaryActionCount,
            3
        )
        XCTAssertEqual(
            TerminalFloatingControlPreferences.Style.radial.maximumSecondaryActionCount,
            7
        )
        XCTAssertEqual(
            TerminalFloatingControlPreferences.defaultCompactActionLayout.allActions,
            [.voiceInput, .system(.backspace), .system(.escape), .keyboard]
        )
        XCTAssertEqual(
            Set(TerminalFloatingControlPreferences.Action.available).count,
            TerminalFloatingControlPreferences.Action.available.count
        )
    }

    func testCodableRoundTripPreservesHiddenSideAndBothLayouts() throws {
        let preferences = TerminalFloatingControlPreferences(
            style: .radial,
            compactActionLayout: .init(
                primaryAction: .keyboard,
                secondaryActions: [.voiceInput]
            ),
            radialActionLayout: .init(
                primaryAction: .system(.escape),
                secondaryActions: [.voiceInput, .keyboard, .system(.tab)]
            ),
            hiddenSide: .right,
            horizontalFraction: 0.3,
            verticalFraction: 0.7
        )

        let decoded = try JSONDecoder().decode(
            TerminalFloatingControlPreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        XCTAssertEqual(decoded, preferences)
    }
}
