import Foundation

nonisolated enum TerminalFloatingControlPresentationPolicy {
    nonisolated enum Presentation: Equatable, Sendable {
        case hidden
        case visible(TerminalFloatingControlPreferences.ActiveStyle)
    }

    nonisolated struct Facts: Equatable, Sendable {
        let isPhone: Bool
        let isTerminalSelected: Bool
        let hasFocusedPane: Bool
        let keyboardIsUserHidden: Bool
        let isSoftwareKeyboardVisible: Bool
        let findNavigatorIsVisible: Bool
        let isZenModeEnabled: Bool
        let isFloatingControlShownInZen: Bool
        let preferences: TerminalFloatingControlPreferences
        let hasProAccess: Bool
        let inputPhase: TerminalFloatingInputPhase
    }

    static func presentation(for facts: Facts) -> Presentation {
        guard facts.isPhone,
              facts.isTerminalSelected,
              facts.hasFocusedPane else {
            return .hidden
        }

        let activeStyle = facts.preferences.activeStyle(
            hasProAccess: facts.hasProAccess
        )

        if facts.inputPhase.requiresVisibleControl {
            return .visible(activeStyle ?? .compact)
        }

        guard !facts.isSoftwareKeyboardVisible else {
            return .hidden
        }

        if facts.isZenModeEnabled {
            guard facts.isFloatingControlShownInZen,
                  let activeStyle else {
                return .hidden
            }
            return .visible(activeStyle)
        }

        guard facts.keyboardIsUserHidden,
              !facts.findNavigatorIsVisible,
              let activeStyle else {
            return .hidden
        }
        return .visible(activeStyle)
    }
}
