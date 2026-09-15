#if os(iOS)
nonisolated enum TerminalKeyboardRouteActivationPolicy {
    nonisolated enum SceneActivation: Sendable {
        case foregroundActive
        case foregroundInactive
        case background
    }

    nonisolated enum Effect: Equatable, Sendable {
        case activate
        /// Preserve the user's typing intent while relinquishing UIKit's
        /// first-responder ownership until this scene becomes locally active.
        case suspend
        case deactivate
    }

    nonisolated enum WindowOwnership: Equatable, Sendable {
        case unknown
        case key
        case notKey
    }

    nonisolated enum PresentationOwnership: Equatable, Sendable {
        case terminal
        case routeModal
    }

    static func effect(
        routeVisible: Bool,
        terminalSelected: Bool,
        sceneActivation: SceneActivation,
        windowOwnership: WindowOwnership = .unknown,
        presentationOwnership: PresentationOwnership = .terminal,
        contentObscured: Bool = false,
        appLockRequired: Bool = false,
        inputMode: TerminalInputMode = .direct
    ) -> Effect {
        guard routeVisible,
              terminalSelected,
              presentationOwnership == .terminal else {
            return .deactivate
        }
        if contentObscured {
            return inputMode == .chat && sceneActivation == .foregroundInactive && !appLockRequired
                ? .suspend : .deactivate
        }
        switch sceneActivation {
        case .foregroundActive:
            if windowOwnership == .notKey { return inputMode == .chat ? .suspend : .deactivate }
            return .activate
        case .foregroundInactive, .background:
            return .suspend
        }
    }
}
#endif
