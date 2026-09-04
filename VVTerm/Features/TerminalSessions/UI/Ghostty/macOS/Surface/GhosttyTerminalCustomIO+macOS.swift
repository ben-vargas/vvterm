//
//  GhosttyTerminalCustomIO+macOS.swift
//  VVTerm
//
//  macOS custom terminal data and input forwarding.
//

#if os(macOS)
import Foundation

extension GhosttyTerminalView {
    @discardableResult
    func receiveTerminalOutput(_ data: Data) async -> Bool {
        guard !isShuttingDown, let terminalOutputRuntime else { return false }
        guard await terminalOutputRuntime.write(data) else { return false }
        guard !isShuttingDown else { return false }
        requestRender()
        return true
    }

    /// Setup the write callback to capture keyboard input
    /// Call this after the surface is created to start receiving input
    func setupWriteCallback() {
        guard let surface = surface?.unsafeCValue else { return }
        guard let userdata = ghostty_surface_userdata(surface) else { return }

        ghostty_surface_set_write_callback(
            surface,
            ghosttyTerminalWriteCallback,
            userdata
        )
    }

    /// Send text to the terminal (used by voice input)
    func sendText(_ text: String) {
        surface?.sendText(text)
        requestRender()
    }

    func pasteTextFromClipboard() {
        _ = surface?.perform(action: "paste_from_clipboard")
        requestRender()
    }

    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        guard let surface = surface else { return }
        let escapeSequence = TerminalSpecialKeySequence.escapeSequence(for: key)
        surface.sendText(escapeSequence)
        requestRender()
    }

    /// Send a control key combination (Ctrl+C, Ctrl+D, etc.)
    func sendControlKey(_ char: Character) {
        guard let surface = surface else { return }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            surface.sendText(String(controlChar))
            requestRender()
        }
    }
}

#endif
