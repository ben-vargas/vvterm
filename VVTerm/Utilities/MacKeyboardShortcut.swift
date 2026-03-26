#if os(macOS)
import AppKit

struct MacKeyboardShortcut {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init?(key: Ghostty.Input.Key, modifiers: NSEvent.ModifierFlags) {
        guard let keyCode = key.keyCode else { return nil }
        self.keyCode = keyCode
        self.modifiers = Self.normalize(modifiers)
    }

    func matches(_ event: NSEvent) -> Bool {
        matches(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode && Self.normalize(modifiers) == self.modifiers
    }

    private static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    private static func normalize(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(relevantModifierMask)
    }
}

enum MacTerminalShortcut {
    static let copy = MacKeyboardShortcut(key: .c, modifiers: .command)!
    static let paste = MacKeyboardShortcut(key: .v, modifiers: .command)!
    static let richPaste = MacKeyboardShortcut(key: .v, modifiers: .control)!
    static let toggleVoiceRecording = MacKeyboardShortcut(key: .m, modifiers: [.command, .shift])!
}

enum MacAppShortcutTrigger: CaseIterable {
    case newWindow
    case newTab
    case splitDownOrDiscoverLocalDevices
    case closeTab
    case openSettings
    case previousTab
    case nextTab
    case toggleZenMode
    case splitRight
    case closePane

    var shortcut: MacKeyboardShortcut {
        switch self {
        case .newWindow:
            MacKeyboardShortcut(key: .n, modifiers: .command)!
        case .newTab:
            MacKeyboardShortcut(key: .t, modifiers: .command)!
        case .splitDownOrDiscoverLocalDevices:
            MacKeyboardShortcut(key: .d, modifiers: [.command, .shift])!
        case .closeTab:
            MacKeyboardShortcut(key: .w, modifiers: .command)!
        case .openSettings:
            MacKeyboardShortcut(key: .comma, modifiers: .command)!
        case .previousTab:
            MacKeyboardShortcut(key: .bracketLeft, modifiers: [.command, .shift])!
        case .nextTab:
            MacKeyboardShortcut(key: .bracketRight, modifiers: [.command, .shift])!
        case .toggleZenMode:
            MacKeyboardShortcut(key: .z, modifiers: [.command, .control])!
        case .splitRight:
            MacKeyboardShortcut(key: .d, modifiers: .command)!
        case .closePane:
            MacKeyboardShortcut(key: .w, modifiers: [.command, .shift])!
        }
    }

    static func matching(_ event: NSEvent) -> Self? {
        matching(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    static func matching(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        allCases.first { $0.shortcut.matches(keyCode: keyCode, modifiers: modifiers) }
    }
}

struct MacAppShortcutActions {
    var newWindow: (() -> Void)?
    var newTab: (() -> Void)?
    var discoverLocalDevices: (() -> Void)?
    var closeTab: (() -> Void)?
    var openSettings: (() -> Void)?
    var previousTab: (() -> Void)?
    var nextTab: (() -> Void)?
    var toggleZenMode: (() -> Void)?
    var splitRight: (() -> Void)?
    var splitDown: (() -> Void)?
    var closePane: (() -> Void)?

    static let empty = Self()

    func action(for trigger: MacAppShortcutTrigger) -> (() -> Void)? {
        switch trigger {
        case .newWindow:
            newWindow
        case .newTab:
            newTab
        case .splitDownOrDiscoverLocalDevices:
            splitDown ?? discoverLocalDevices
        case .closeTab:
            closeTab
        case .openSettings:
            openSettings
        case .previousTab:
            previousTab
        case .nextTab:
            nextTab
        case .toggleZenMode:
            toggleZenMode
        case .splitRight:
            splitRight
        case .closePane:
            closePane
        }
    }

    @discardableResult
    func perform(_ trigger: MacAppShortcutTrigger) -> Bool {
        guard let action = action(for: trigger) else { return false }
        action()
        return true
    }

    func mergingGlobals(from fallback: MacAppShortcutActions) -> MacAppShortcutActions {
        MacAppShortcutActions(
            newWindow: newWindow ?? fallback.newWindow,
            newTab: newTab,
            discoverLocalDevices: discoverLocalDevices,
            closeTab: closeTab,
            openSettings: openSettings ?? fallback.openSettings,
            previousTab: previousTab ?? fallback.previousTab,
            nextTab: nextTab ?? fallback.nextTab,
            toggleZenMode: toggleZenMode,
            splitRight: splitRight,
            splitDown: splitDown,
            closePane: closePane
        )
    }
}
#endif
