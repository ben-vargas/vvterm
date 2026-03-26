#if os(macOS)
import AppKit
import SwiftUI

@MainActor
private final class MacAppShortcutMonitor {
    static let shared = MacAppShortcutMonitor()

    private struct Registration {
        weak var window: NSWindow?
        var actions: MacAppShortcutActions
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var localMonitor: Any?

    func register(window: NSWindow, actions: MacAppShortcutActions) {
        registrations[ObjectIdentifier(window)] = Registration(window: window, actions: actions)
        installMonitorIfNeeded()
    }

    func unregister(window: NSWindow) {
        registrations.removeValue(forKey: ObjectIdentifier(window))
        removeMonitorIfPossible()
    }

    private func installMonitorIfNeeded() {
        pruneRegistrations()
        guard localMonitor == nil, !registrations.isEmpty else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeMonitorIfPossible() {
        pruneRegistrations()
        guard registrations.isEmpty, let localMonitor else { return }
        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }

    private func pruneRegistrations() {
        registrations = registrations.filter { $0.value.window != nil }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !event.isARepeat,
              let trigger = MacAppShortcutTrigger.matching(event) else {
            return event
        }

        pruneRegistrations()
        let actions = actions(for: event)
        guard actions.perform(trigger) else { return event }
        return nil
    }

    private func actions(for event: NSEvent) -> MacAppShortcutActions {
        let fallback = registrations.values.first?.actions ?? .empty
        guard let window = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              let registration = registrations[ObjectIdentifier(window)] else {
            return fallback
        }

        return registration.actions.mergingGlobals(from: fallback)
    }
}

private struct MacAppShortcutBindingBridge: NSViewRepresentable {
    let actions: MacAppShortcutActions

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView()
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.actions = actions
        nsView.updateRegistration()
    }

    static func dismantleNSView(_ nsView: RegistrationView, coordinator: ()) {
        nsView.unregister()
    }

    final class RegistrationView: NSView {
        var actions: MacAppShortcutActions = .empty
        private weak var registeredWindow: NSWindow?

        override var intrinsicContentSize: NSSize { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRegistration()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateRegistration()
        }

        func updateRegistration() {
            if let registeredWindow, registeredWindow !== window {
                MacAppShortcutMonitor.shared.unregister(window: registeredWindow)
                self.registeredWindow = nil
            }

            guard let window else { return }
            MacAppShortcutMonitor.shared.register(window: window, actions: actions)
            registeredWindow = window
        }

        func unregister() {
            guard let registeredWindow else { return }
            MacAppShortcutMonitor.shared.unregister(window: registeredWindow)
            self.registeredWindow = nil
        }

        deinit {
            unregister()
        }
    }
}

struct MacAppShortcutBindingsView: View {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.openTerminalTab) private var openTerminalTab
    @FocusedValue(\.openLocalSSHDiscovery) private var openLocalSSHDiscovery
    @FocusedValue(\.terminalSplitActions) private var terminalSplitActions
    @FocusedValue(\.toggleZenMode) private var toggleZenMode

    private var actions: MacAppShortcutActions {
        MacAppShortcutActions(
            newWindow: {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            },
            newTab: openTerminalTab,
            discoverLocalDevices: openLocalSSHDiscovery,
            closeTab: terminalSplitActions?.closePane,
            openSettings: {
                SettingsWindowManager.shared.show()
            },
            previousTab: {
                ConnectionSessionManager.shared.selectPreviousSession()
            },
            nextTab: {
                ConnectionSessionManager.shared.selectNextSession()
            },
            toggleZenMode: toggleZenMode,
            splitRight: terminalSplitActions?.splitHorizontal,
            splitDown: terminalSplitActions?.splitVertical,
            closePane: terminalSplitActions?.closePane
        )
    }

    var body: some View {
        MacAppShortcutBindingBridge(actions: actions)
            .frame(width: 0, height: 0)
    }
}
#endif
