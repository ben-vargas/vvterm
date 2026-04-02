//
//  TerminalSplitContainerView.swift
//  VVTerm
//
//  Split menu commands and focused values for terminal splits (macOS only)
//

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Split Menu Commands

struct SplitCommands: Commands {
    @FocusedValue(\.activeServerId) var activeServerId
    @FocusedValue(\.activePaneId) var activePaneId
    @FocusedValue(\.terminalSplitActions) var splitActions
    @FocusedValue(\.toggleZenMode) var toggleZenMode
    @FocusedValue(\.isZenModeEnabled) var isZenModeEnabled

    var body: some Commands {
        CommandMenu("Terminal") {
            Button(isZenModeEnabled == true ? "Exit Zen Mode" : "Enter Zen Mode") {
                toggleZenMode?()
            }
            .keyboardShortcut("z", modifiers: [.command, .control])
            .disabled(toggleZenMode == nil)

            Divider()

            Group {
                Button("Split Right") {
                    splitActions?.splitHorizontal()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!canSplit)

                Button("Split Down") {
                    splitActions?.splitVertical()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!canSplit)

                Divider()

                Button("Close Pane") {
                    splitActions?.closePane()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!hasActivePane)
            }
        }
    }

    private var canSplit: Bool {
        return splitActions != nil && activePaneId != nil
    }

    private var hasActivePane: Bool {
        activePaneId != nil && splitActions != nil
    }
}

// MARK: - Split Actions

/// Actions that can be performed on a terminal split layout
struct TerminalSplitActions {
    let splitHorizontal: () -> Void
    let splitVertical: () -> Void
    let closePane: () -> Void
}

// MARK: - Focused Values

struct ActiveServerIdKey: FocusedValueKey {
    typealias Value = UUID
}

struct ActivePaneIdKey: FocusedValueKey {
    typealias Value = UUID
}

struct TerminalSplitActionsKey: FocusedValueKey {
    typealias Value = TerminalSplitActions
}

struct OpenTerminalTabActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct OpenLocalSSHDiscoveryActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ToggleZenModeActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZenModeEnabledKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var activeServerId: UUID? {
        get { self[ActiveServerIdKey.self] }
        set { self[ActiveServerIdKey.self] = newValue }
    }

    var activePaneId: UUID? {
        get { self[ActivePaneIdKey.self] }
        set { self[ActivePaneIdKey.self] = newValue }
    }

    var terminalSplitActions: TerminalSplitActions? {
        get { self[TerminalSplitActionsKey.self] }
        set { self[TerminalSplitActionsKey.self] = newValue }
    }

    var openTerminalTab: (() -> Void)? {
        get { self[OpenTerminalTabActionKey.self] }
        set { self[OpenTerminalTabActionKey.self] = newValue }
    }

    var openLocalSSHDiscovery: (() -> Void)? {
        get { self[OpenLocalSSHDiscoveryActionKey.self] }
        set { self[OpenLocalSSHDiscoveryActionKey.self] = newValue }
    }

    var toggleZenMode: (() -> Void)? {
        get { self[ToggleZenModeActionKey.self] }
        set { self[ToggleZenModeActionKey.self] = newValue }
    }

    var isZenModeEnabled: Bool? {
        get { self[ZenModeEnabledKey.self] }
        set { self[ZenModeEnabledKey.self] = newValue }
    }
}

#endif
