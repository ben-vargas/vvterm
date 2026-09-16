#if os(iOS)
import SwiftUI

/// The same session actions are available from the toolbar and the Zen panel.
struct TerminalSessionMenuActions: View {
    enum Style { case menu, zen }
    enum ZenMode { case unavailable, inactive, active }

    let style: Style
    let isTerminalSelected: Bool
    let zenMode: ZenMode
    let composer: TerminalComposerStore?
    let canOpenSessions: Bool
    let canDisconnect: Bool
    let perform: (TerminalSessionCommand) -> Void

    var body: some View {
        if canOpenSessions {
            action(.sessions, title: "Sessions", icon: "rectangle.stack")
        }
        if isTerminalSelected {
            action(.find, title: "Find", icon: "magnifyingglass")
            Menu {
                Button { perform(.keyboard) } label: { Label("Keyboard", systemImage: "keyboard") }
                    .accessibilityIdentifier("vvterm.terminal.input.keyboard")
                if let composer { TerminalComposerMenuButton(composer: composer) }
            } label: {
                if style == .zen {
                    Label("Input", systemImage: "keyboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Label("Input", systemImage: "keyboard")
                }
            }
            .accessibilityIdentifier("vvterm.terminal.inputMenu")
        }
        if zenMode != .unavailable {
            action(.toggleZen,
                   title: zenMode == .active ? "Exit Zen Mode" : "Enter Zen Mode",
                   icon: zenMode == .active ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        action(.settings, title: "Settings", icon: "gear")
        if canDisconnect {
            if style == .menu { Divider() }
            if style == .zen {
                ZenModeActionButton(title: "Disconnect", systemImage: "xmark.circle", tint: .red) {
                    perform(.disconnect)
                }
                .accessibilityIdentifier("vvterm.terminal.zen.disconnect")
            } else {
                Button(role: .destructive) { perform(.disconnect) } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func action(_ command: TerminalSessionCommand, title: LocalizedStringKey, icon: String) -> some View {
        Group {
            if style == .zen {
                ZenModeActionButton(title: title, systemImage: icon) { perform(command) }
            } else {
                Button { perform(command) } label: { Label(title, systemImage: icon) }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier(for: command))
    }

    private func accessibilityIdentifier(for command: TerminalSessionCommand) -> String {
        let actionID = command == .toggleZen
            ? (zenMode == .active ? "exitZenMode" : "enterZenMode")
            : command.rawValue
        let prefix = style == .zen && actionID != "exitZenMode" ? "zen." : ""
        return "vvterm.terminal.\(prefix)\(actionID)"
    }
}
#endif
