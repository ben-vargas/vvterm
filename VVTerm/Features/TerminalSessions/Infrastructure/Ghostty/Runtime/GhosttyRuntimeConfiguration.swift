import Foundation

extension Ghostty {
    struct RuntimeConfiguration: Equatable {
        let fontSelection: TerminalFontRuntimeSelection
        let fontSize: Double
        let contentPadding: TerminalContentPadding
        let cursorStyle: TerminalCursorStyle
        let cursorBlink: Bool
        let optionAsAltMode: TerminalOptionAsAltMode
        let remoteClipboardPolicy: TerminalRemoteClipboardPolicy

        init(
            fontSelection: TerminalFontRuntimeSelection,
            fontSize: Double,
            contentPadding: TerminalContentPadding,
            cursorStyleRawValue: String,
            cursorBlink: Bool,
            optionAsAltModeRawValue: String,
            remoteClipboardPolicyRawValue: String
        ) {
            self.fontSelection = fontSelection
            self.fontSize = TerminalDefaults.clampedFontSize(fontSize)
            self.contentPadding = contentPadding
            self.cursorStyle = TerminalCursorStyle(rawValue: cursorStyleRawValue)
                ?? TerminalDefaults.defaultCursorStyle
            self.cursorBlink = cursorBlink
            self.optionAsAltMode = TerminalOptionAsAltMode(rawValue: optionAsAltModeRawValue)
                ?? .none
            self.remoteClipboardPolicy = TerminalRemoteClipboardPolicy(
                rawValue: remoteClipboardPolicyRawValue
            ) ?? .defaultValue
        }

        @MainActor static var defaultValue: Self {
            Self(
                fontSelection: .defaultValue,
                fontSize: TerminalDefaults.defaultFontSize,
                contentPadding: .defaultValue,
                cursorStyleRawValue: TerminalDefaults.defaultCursorStyle.rawValue,
                cursorBlink: TerminalDefaults.defaultCursorBlink,
                optionAsAltModeRawValue: TerminalOptionAsAltMode.none.rawValue,
                remoteClipboardPolicyRawValue: TerminalRemoteClipboardPolicy.defaultValue.rawValue
            )
        }
    }
}
