#if os(iOS)
import Foundation

extension TerminalComposerSendAction.Step {
    func keyEvents() throws -> (press: Ghostty.Input.KeyEvent, release: Ghostty.Input.KeyEvent)? {
        guard case .key(let key, let modifiers) = input else { return nil }
        guard let nativeKey = Ghostty.Input.Key(rawValue: key.rawValue) else {
            throw TerminalAttachmentError.unavailable
        }
        let text = modifiers.control || modifiers.alternate || modifiers.command
            ? nil : (modifiers.shift ? key.shiftedText ?? key.unshiftedText : key.unshiftedText)
        return (
            .init(key: nativeKey, text: text, mods: modifiers.ghosttyModifiers,
                  unshiftedCodepoint: key.unshiftedText?.unicodeScalars.first?.value ?? 0),
            .init(key: nativeKey, action: .release, mods: modifiers.ghosttyModifiers)
        )
    }
}
#endif
