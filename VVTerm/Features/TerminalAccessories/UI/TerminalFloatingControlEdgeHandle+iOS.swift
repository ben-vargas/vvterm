#if os(iOS)
import SwiftUI

struct TerminalFloatingControlEdgeHandle: View {
    let side: TerminalFloatingControlPreferences.HiddenSide
    var isInteractive = true
    var accessibilityIdentifier = "vvterm.terminal.floating.edgeHandle"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                handleSurface
                Image(systemName: side == .left ? "chevron.right" : "chevron.left")
                    .font(.system(size: 13, weight: .bold))
            }
            .frame(
                width: TerminalFloatingControlLayout.edgeHandleVisualSize.width,
                height: TerminalFloatingControlLayout.edgeHandleVisualSize.height
            )
            .frame(
                width: TerminalFloatingControlLayout.edgeHandleSize.width,
                height: TerminalFloatingControlLayout.edgeHandleSize.height,
                alignment: side == .left ? .leading : .trailing
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isInteractive)
        .accessibilityLabel("Show Floating Controls")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var handleSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(iOS 26, *) {
            shape
                .fill(.clear)
                .glassEffect(
                    isInteractive ? .regular.interactive() : .regular,
                    in: shape
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
        }
    }
}
#endif
