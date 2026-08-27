import Testing
@testable import VVTerm

@MainActor
struct GhosttyRuntimeConfigurationTests {
    @Test
    func rawSettingsMapToTypedRuntimeConfiguration() {
        let fontSelection = TerminalFontRuntimeSelection(
            primaryFamily: "Menlo",
            cjkFamily: "Noto Sans CJK"
        )
        let configuration = Ghostty.RuntimeConfiguration(
            fontSelection: fontSelection,
            fontSize: TerminalDefaults.maximumFontSize + 20,
            contentPadding: TerminalContentPadding(horizontal: -2, vertical: 50),
            cursorStyleRawValue: "invalid-cursor",
            cursorBlink: false,
            optionAsAltModeRawValue: TerminalOptionAsAltMode.right.rawValue,
            remoteClipboardReadPolicyRawValue: "invalid-clipboard-policy"
        )

        #expect(configuration.fontSelection == fontSelection)
        #expect(configuration.fontSize == TerminalDefaults.maximumFontSize)
        #expect(configuration.contentPadding == TerminalContentPadding(horizontal: 0, vertical: 32))
        #expect(configuration.cursorStyle == TerminalDefaults.defaultCursorStyle)
        #expect(configuration.cursorBlink == false)
        #expect(configuration.optionAsAltMode == .right)
        #expect(configuration.remoteClipboardReadPolicy == .defaultValue)
    }

    @Test
    func appAcceptsRuntimeConfigurationBeforeStartup() {
        let configuration = Ghostty.RuntimeConfiguration(
            fontSelection: .defaultValue,
            fontSize: 14,
            contentPadding: TerminalContentPadding(horizontal: 5, vertical: 7),
            cursorStyleRawValue: TerminalCursorStyle.bar.rawValue,
            cursorBlink: false,
            optionAsAltModeRawValue: TerminalOptionAsAltMode.left.rawValue,
            remoteClipboardReadPolicyRawValue: TerminalRemoteClipboardReadPolicy.deny.rawValue
        )
        let app = GhosttyRuntime(autoStart: false)

        app.applyConfiguration(configuration)

        #expect(app.readiness == .idle)
        #expect(app.configuration == configuration)
    }

    @Test
    func paddingParticipatesInRuntimeEquality() {
        let zeroPadding = configuration(contentPadding: .defaultValue)
        let customPadding = configuration(
            contentPadding: TerminalContentPadding(horizontal: 12, vertical: 18)
        )

        #expect(zeroPadding != customPadding)
    }

    private func configuration(
        contentPadding: TerminalContentPadding
    ) -> Ghostty.RuntimeConfiguration {
        Ghostty.RuntimeConfiguration(
            fontSelection: .defaultValue,
            fontSize: 14,
            contentPadding: contentPadding,
            cursorStyleRawValue: TerminalCursorStyle.block.rawValue,
            cursorBlink: true,
            optionAsAltModeRawValue: TerminalOptionAsAltMode.none.rawValue,
            remoteClipboardReadPolicyRawValue: TerminalRemoteClipboardReadPolicy.defaultValue.rawValue
        )
    }
}
