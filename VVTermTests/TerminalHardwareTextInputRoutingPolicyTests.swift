import Testing
@testable import VVTerm

struct TerminalHardwareTextInputRoutingPolicyTests {
    @Test
    func routesPrintablePinyinKeysToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func routesPrintableKanaKeysToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func routesPrintableHangulKeysToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func routesLatinPrintableKeysToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func keepsTerminalFallbackKeysOffSystemTextInputEvenInCJKLayouts() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func routesCapsLockToggleToSystemTextInputEvenThoughItIsFallbackKey() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: true,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func alwaysRoutesActiveCompositionThroughSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func keepsModifiedPrintableKeysOnDirectGhosttyPath() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: true,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: true,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
    }
}

struct TerminalKeyboardFocusPolicyTests {
    @Test
    func startsAutomaticWithoutReconnectRestore() {
        let policy = TerminalKeyboardFocusPolicy()

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect == false)
    }

    @Test
    func userDismissalDisablesAutomaticFocusUntilExplicitRefocus() {
        var policy = TerminalKeyboardFocusPolicy()

        policy.requestFocus()
        policy.dismissForUser()

        #expect(policy.allowsAutomaticFocus == false)
        #expect(policy.shouldRestoreOnReconnect == false)

        policy.requestFocus()

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect)
    }

    @Test
    func reconnectRestoreReEnablesAutomaticFocusAfterManualDismissal() {
        var policy = TerminalKeyboardFocusPolicy()

        policy.dismissForUser()
        policy.markForReconnect()

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect)
    }

    @Test
    func clearingReconnectIntentPreservesFocusMode() {
        var policy = TerminalKeyboardFocusPolicy()

        policy.requestFocus()
        policy.clearReconnect()

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect == false)

        policy.dismissForUser()
        policy.clearReconnect()

        #expect(policy.allowsAutomaticFocus == false)
        #expect(policy.shouldRestoreOnReconnect == false)
    }
}
