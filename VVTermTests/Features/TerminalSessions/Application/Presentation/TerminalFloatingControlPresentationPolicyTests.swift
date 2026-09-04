import XCTest
@testable import VVTerm

final class TerminalFloatingControlPresentationPolicyTests: XCTestCase {
    func testCompactNeedsExplicitKeyboardDismissal() {
        XCTAssertEqual(presentation(), .hidden)
        XCTAssertEqual(
            presentation(keyboardIsUserHidden: true),
            .visible(.compact)
        )
    }

    func testOffHidesIdleControl() {
        XCTAssertEqual(
            presentation(
                keyboardIsUserHidden: true,
                preferences: .init(style: .off)
            ),
            .hidden
        )
    }

    func testFreeAccessUsesCompactForSavedRadialStyle() {
        XCTAssertEqual(
            presentation(
                keyboardIsUserHidden: true,
                preferences: .init(style: .radial),
                hasProAccess: false
            ),
            .visible(.compact)
        )
    }

    func testProAccessUsesSavedRadialStyle() {
        XCTAssertEqual(
            presentation(
                keyboardIsUserHidden: true,
                preferences: .init(style: .radial),
                hasProAccess: true
            ),
            .visible(.radial)
        )
    }

    func testFindNavigatorHidesIdleControl() {
        XCTAssertEqual(
            presentation(
                keyboardIsUserHidden: true,
                findNavigatorIsVisible: true
            ),
            .hidden
        )
    }

    func testSoftwareKeyboardHidesIdleControlInsideAndOutsideZen() {
        XCTAssertEqual(
            presentation(
                keyboardIsUserHidden: true,
                isSoftwareKeyboardVisible: true
            ),
            .hidden
        )
        XCTAssertEqual(
            presentation(
                isSoftwareKeyboardVisible: true,
                isZenModeEnabled: true
            ),
            .hidden
        )
    }

    func testEachActiveInputPhaseOverridesIdleVisibilityRules() {
        for phase in [
            TerminalFloatingInputPhase.starting,
            .recording,
            .processing,
            .pendingReturn,
        ] {
            XCTAssertEqual(
                presentation(
                    isSoftwareKeyboardVisible: true,
                    findNavigatorIsVisible: true,
                    preferences: .init(style: .off),
                    inputPhase: phase
                ),
                .visible(.compact)
            )
        }
    }

    func testPendingReturnKeepsRadialControlVisible() {
        XCTAssertEqual(
            presentation(
                preferences: .init(style: .radial),
                hasProAccess: true,
                inputPhase: .pendingReturn
            ),
            .visible(.radial)
        )
    }

    func testZenUsesConfiguredControl() {
        XCTAssertEqual(
            presentation(
                isZenModeEnabled: true,
                preferences: .init(style: .radial),
                hasProAccess: true
            ),
            .visible(.radial)
        )
    }

    func testZenCanHideIdleConfiguredControl() {
        XCTAssertEqual(
            presentation(
                isZenModeEnabled: true,
                isFloatingControlShownInZen: false,
                preferences: .init(style: .radial),
                hasProAccess: true
            ),
            .hidden
        )
    }

    func testZenRespectsOffWhileIdle() {
        XCTAssertEqual(
            presentation(
                isZenModeEnabled: true,
                preferences: .init(style: .off)
            ),
            .hidden
        )
    }

    func testZenShowsSafeControlDuringVoiceWork() {
        XCTAssertEqual(
            presentation(
                isZenModeEnabled: true,
                isFloatingControlShownInZen: false,
                preferences: .init(style: .off),
                inputPhase: .processing
            ),
            .visible(.compact)
        )
    }

    func testMissingTerminalHidesInputControl() {
        XCTAssertEqual(presentation(isTerminalSelected: false), .hidden)
        XCTAssertEqual(
            presentation(isTerminalSelected: false, inputPhase: .recording),
            .hidden
        )
    }

    private func presentation(
        isPhone: Bool = true,
        isTerminalSelected: Bool = true,
        hasFocusedPane: Bool = true,
        keyboardIsUserHidden: Bool = false,
        isSoftwareKeyboardVisible: Bool = false,
        findNavigatorIsVisible: Bool = false,
        isZenModeEnabled: Bool = false,
        isFloatingControlShownInZen: Bool = true,
        preferences: TerminalFloatingControlPreferences = .defaultValue,
        hasProAccess: Bool = false,
        inputPhase: TerminalFloatingInputPhase = .idle
    ) -> TerminalFloatingControlPresentationPolicy.Presentation {
        TerminalFloatingControlPresentationPolicy.presentation(
            for: .init(
                isPhone: isPhone,
                isTerminalSelected: isTerminalSelected,
                hasFocusedPane: hasFocusedPane,
                keyboardIsUserHidden: keyboardIsUserHidden,
                isSoftwareKeyboardVisible: isSoftwareKeyboardVisible,
                findNavigatorIsVisible: findNavigatorIsVisible,
                isZenModeEnabled: isZenModeEnabled,
                isFloatingControlShownInZen: isFloatingControlShownInZen,
                preferences: preferences,
                hasProAccess: hasProAccess,
                inputPhase: inputPhase
            )
        )
    }
}
