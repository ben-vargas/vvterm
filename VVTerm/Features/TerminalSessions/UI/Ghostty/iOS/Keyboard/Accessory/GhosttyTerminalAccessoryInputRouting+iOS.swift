//
//  GhosttyTerminalAccessoryInputRouting+iOS.swift
//  VVTerm
//
//  iOS terminal accessory input routing.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    enum KeyInputOrigin {
        case textInput
        case accessory
    }

    func canRouteKeyInput(from origin: KeyInputOrigin) -> Bool {
        switch origin {
        case .textInput: canRouteTerminalInput
        case .accessory: canInteractWithTerminalContent && isTextInputSessionEligible
        }
    }

    @discardableResult
    func performAccessorySystemAction(_ actionID: TerminalAccessorySystemActionID) -> Bool {
        guard canRouteTerminalInput, let terminalKey = actionID.terminalKey else { return false }
        sendToolbarKey(terminalKey)
        return true
    }

    func sendToolbarKey(_ key: TerminalKey, accumulatedMods: Ghostty.Input.Mods = [], origin: KeyInputOrigin = .textInput) {
        guard canRouteKeyInput(from: origin) else { return }
        if case .modified(let baseKey, let mods) = key {
            sendToolbarKey(baseKey, accumulatedMods: accumulatedMods.union(mods), origin: origin)
            return
        }
        if accumulatedMods.contains(.super),
           let splitKey = key.terminalSplitShortcutKey,
           performTerminalSplitShortcut(
               key: splitKey,
               modifiers: accumulatedMods.terminalSplitShortcutModifiers
           ) {
            return
        }

        switch key {
        case .modified:
            return
        case .escape:
            if accumulatedMods.isEmpty, canRouteTerminalInput, hasLocalTextInputSession {
                invalidateLocalTextInputSession()
                sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false, origin: origin)
            } else {
                sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false, origin: origin)
            }
        case .tab:
            sendToolbarGhosttyKey(.tab, mods: accumulatedMods, origin: origin)
        case .enter:
            sendToolbarGhosttyKey(.enter, mods: accumulatedMods, origin: origin)
        case .backspace:
            if accumulatedMods.isEmpty, canRouteTerminalInput, hasLocalTextInputSession {
                imeProxyTextView.deleteBackward()
            } else {
                sendToolbarGhosttyKey(.backspace, mods: accumulatedMods, origin: origin)
            }
        case .delete:
            sendToolbarGhosttyKey(.delete, mods: accumulatedMods, origin: origin)
        case .insert:
            sendToolbarGhosttyKey(.insert, mods: accumulatedMods, origin: origin)
        case .arrowUp:
            sendToolbarGhosttyKey(.arrowUp, mods: accumulatedMods, origin: origin)
        case .arrowDown:
            sendToolbarGhosttyKey(.arrowDown, mods: accumulatedMods, origin: origin)
        case .arrowLeft:
            sendToolbarGhosttyKey(.arrowLeft, mods: accumulatedMods, origin: origin)
        case .arrowRight:
            sendToolbarGhosttyKey(.arrowRight, mods: accumulatedMods, origin: origin)
        case .home:
            sendToolbarGhosttyKey(.home, mods: accumulatedMods, origin: origin)
        case .end:
            sendToolbarGhosttyKey(.end, mods: accumulatedMods, origin: origin)
        case .pageUp:
            sendToolbarGhosttyKey(.pageUp, mods: accumulatedMods, origin: origin)
        case .pageDown:
            sendToolbarGhosttyKey(.pageDown, mods: accumulatedMods, origin: origin)
        case .f1:
            sendToolbarGhosttyKey(.f1, mods: accumulatedMods, origin: origin)
        case .f2:
            sendToolbarGhosttyKey(.f2, mods: accumulatedMods, origin: origin)
        case .f3:
            sendToolbarGhosttyKey(.f3, mods: accumulatedMods, origin: origin)
        case .f4:
            sendToolbarGhosttyKey(.f4, mods: accumulatedMods, origin: origin)
        case .f5:
            sendToolbarGhosttyKey(.f5, mods: accumulatedMods, origin: origin)
        case .f6:
            sendToolbarGhosttyKey(.f6, mods: accumulatedMods, origin: origin)
        case .f7:
            sendToolbarGhosttyKey(.f7, mods: accumulatedMods, origin: origin)
        case .f8:
            sendToolbarGhosttyKey(.f8, mods: accumulatedMods, origin: origin)
        case .f9:
            sendToolbarGhosttyKey(.f9, mods: accumulatedMods, origin: origin)
        case .f10:
            sendToolbarGhosttyKey(.f10, mods: accumulatedMods, origin: origin)
        case .f11:
            sendToolbarGhosttyKey(.f11, mods: accumulatedMods, origin: origin)
        case .f12:
            sendToolbarGhosttyKey(.f12, mods: accumulatedMods, origin: origin)
        case .ctrlC:
            sendToolbarControlShortcut(.c, letter: "c", mods: accumulatedMods, origin: origin)
        case .ctrlD:
            sendToolbarControlShortcut(.d, letter: "d", mods: accumulatedMods, origin: origin)
        case .ctrlZ:
            sendToolbarControlShortcut(.z, letter: "z", mods: accumulatedMods, origin: origin)
        case .ctrlL:
            sendToolbarControlShortcut(.l, letter: "l", mods: accumulatedMods, origin: origin)
        case .ctrlA:
            sendToolbarControlShortcut(.a, letter: "a", mods: accumulatedMods, origin: origin)
        case .ctrlE:
            sendToolbarControlShortcut(.e, letter: "e", mods: accumulatedMods, origin: origin)
        case .ctrlK:
            sendToolbarControlShortcut(.k, letter: "k", mods: accumulatedMods, origin: origin)
        case .ctrlU:
            sendToolbarControlShortcut(.u, letter: "u", mods: accumulatedMods, origin: origin)
        }
    }

    func sendToolbarGhosttyKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32? = nil,
        invalidateLocalSession: Bool = true,
        origin: KeyInputOrigin = .textInput
    ) {
        guard canRouteKeyInput(from: origin) else { return }
        let codepoint = unshiftedCodepoint ?? text?.unicodeScalars.first?.value ?? 0
        sendModifiedKey(
            key,
            mods: mods,
            text: text,
            unshiftedCodepoint: codepoint,
            invalidateLocalSession: invalidateLocalSession,
            origin: origin
        )
    }

    private func sendToolbarControlShortcut(
        _ key: Ghostty.Input.Key,
        letter: String,
        mods: Ghostty.Input.Mods,
        origin: KeyInputOrigin
    ) {
        var mergedMods = mods
        mergedMods.insert(.ctrl)
        let codepoint = letter.unicodeScalars.first?.value ?? 0
        sendToolbarGhosttyKey(key, mods: mergedMods, text: nil, unshiftedCodepoint: codepoint, origin: origin)
    }

    func handleToolbarCustomAction(_ action: TerminalAccessoryCustomAction) {
        guard canInteractWithTerminalContent, isTextInputSessionEligible else { return }
        switch action.kind {
        case .command:
            surface?.sendText(action.commandContent)
            requestRender()
            if action.commandSendMode == .insertAndEnter {
                sendToolbarGhosttyKey(.enter, mods: [], origin: .accessory)
            }
        case .shortcut:
            if action.shortcutModifiers.command,
               let splitKey = action.shortcutKey.terminalSplitShortcutKey,
               performTerminalSplitShortcut(
                   key: splitKey,
                   modifiers: action.shortcutModifiers.terminalSplitShortcutModifiers
               ) {
                return
            }
            guard let key = Ghostty.Input.Key(rawValue: action.shortcutKey.rawValue) else { return }
            let mods = action.shortcutModifiers.ghosttyModifiers
            let text: String?
            if action.shortcutModifiers.control || action.shortcutModifiers.alternate || action.shortcutModifiers.command {
                text = nil
            } else if action.shortcutModifiers.shift {
                text = action.shortcutKey.shiftedText ?? action.shortcutKey.unshiftedText
            } else {
                text = action.shortcutKey.unshiftedText
            }

            let codepoint = action.shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
            sendToolbarGhosttyKey(key, mods: mods, text: text, unshiftedCodepoint: codepoint, origin: .accessory)
        }
    }

    func ghosttyKeyMapping(for character: Character) -> (key: Ghostty.Input.Key, text: String?, codepoint: UInt32, requiresShift: Bool)? {
        let string = String(character)

        for shortcutKey in TerminalAccessoryShortcutKey.allCases {
            if shortcutKey.unshiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return (ghosttyKey, shortcutKey.unshiftedText, codepoint, false)
            }

            if shortcutKey.shiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return (ghosttyKey, shortcutKey.shiftedText, codepoint, true)
            }
        }

        return nil
    }
}

extension TerminalAccessorySystemActionID {
    var terminalKey: TerminalKey? {
        switch self {
        case .commandModifier: return nil
        case .escape: return .escape
        case .tab: return .tab
        case .shiftTab: return .tab.withShift()
        case .enter: return .enter
        case .backspace: return .backspace
        case .delete: return .delete
        case .insert: return .insert
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .f1: return .f1
        case .f2: return .f2
        case .f3: return .f3
        case .f4: return .f4
        case .f5: return .f5
        case .f6: return .f6
        case .f7: return .f7
        case .f8: return .f8
        case .f9: return .f9
        case .f10: return .f10
        case .f11: return .f11
        case .f12: return .f12
        case .ctrlC: return .ctrlC
        case .ctrlD: return .ctrlD
        case .ctrlZ: return .ctrlZ
        case .ctrlL: return .ctrlL
        case .ctrlA: return .ctrlA
        case .ctrlE: return .ctrlE
        case .ctrlK: return .ctrlK
        case .ctrlU: return .ctrlU
        case .unknown: return nil
        }
    }
}

extension TerminalAccessoryShortcutModifiers {
    var ghosttyModifiers: Ghostty.Input.Mods {
        var mods: Ghostty.Input.Mods = []
        if control {
            mods.insert(.ctrl)
        }
        if alternate {
            mods.insert(.alt)
        }
        if command {
            mods.insert(.super)
        }
        if shift {
            mods.insert(.shift)
        }
        return mods
    }
}

private extension TerminalKey {
    var terminalSplitShortcutKey: TerminalSplitShortcutKey? {
        switch self {
        case .enter:
            return .character("\r")
        case .arrowUp:
            return .upArrow
        case .arrowDown:
            return .downArrow
        case .arrowLeft:
            return .leftArrow
        case .arrowRight:
            return .rightArrow
        default:
            return nil
        }
    }
}

#endif
