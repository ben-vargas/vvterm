#if os(iOS)
import SwiftUI

struct TerminalFloatingControlCircleButtonStyle: ButtonStyle {
    let size: CGFloat
    let tint: Color?
    var isInteractive = true

    func makeBody(configuration: Configuration) -> some View {
        styledLabel(configuration)
            .scaleEffect(isInteractive && configuration.isPressed ? 0.94 : 1)
            .opacity(isInteractive && configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styledLabel(_ configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            if let tint {
                configuration.label
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .glassEffect(
                        isInteractive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                        in: Circle()
                    )
            } else {
                configuration.label
                    .foregroundStyle(.primary)
                    .frame(width: size, height: size)
                    .glassEffect(
                        isInteractive ? .regular.interactive() : .regular,
                        in: Circle()
                    )
            }
        } else {
            configuration.label
                .foregroundStyle(tint == nil ? Color.primary : Color.white)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .background(tint?.opacity(0.72) ?? Color.clear, in: Circle())
                .overlay {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
        }
    }
}
#endif
