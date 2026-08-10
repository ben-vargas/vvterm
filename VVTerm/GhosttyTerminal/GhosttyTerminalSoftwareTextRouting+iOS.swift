//
//  GhosttyTerminalSoftwareTextRouting+iOS.swift
//  VVTerm
//
//  iOS software text and paste routing.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    /// Send text to the terminal (called from keyboard toolbar or software keyboard)
    func sendText(_ text: String) {
        guard canRouteTerminalInput else { return }
        surface?.sendText(text)
        requestRender()
    }

    func pasteTextFromClipboard() {
        guard canRouteTerminalInput else { return }
        _ = surface?.perform(action: "paste_from_clipboard")
        requestRender()
    }

    func sendTerminalInputText(_ text: String) {
        guard canRouteTerminalInput else { return }
        let normalized = text.precomposedStringWithCanonicalMapping
        guard normalized.count == 1, let character = normalized.first else {
            sendRawTerminalInputText(normalized, invalidateLocalSession: false)
            return
        }
        guard let mapping = ghosttyKeyMapping(for: character) else {
            sendRawTerminalInputText(normalized, invalidateLocalSession: false)
            return
        }

        var mods: Ghostty.Input.Mods = []
        if mapping.requiresShift {
            mods.insert(.shift)
        }
        sendModifiedKey(
            mapping.key,
            mods: mods,
            text: mapping.text,
            unshiftedCodepoint: mapping.codepoint,
            invalidateLocalSession: false
        )
    }

    private func sendRawTerminalInputText(_ text: String, invalidateLocalSession: Bool = true) {
        guard canRouteTerminalInput else { return }
        let terminalText = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        let data = Data(terminalText.utf8)
        guard !data.isEmpty else { return }

        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        if let writeCallback {
            writeCallback(data)
        } else {
            surface?.sendText(terminalText)
        }
        requestRender()
    }
}

#endif
