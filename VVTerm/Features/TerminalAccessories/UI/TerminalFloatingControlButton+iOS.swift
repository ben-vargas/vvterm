#if os(iOS)
import SwiftUI

struct TerminalFloatingControlButton: View {
    enum Content: Hashable {
        case systemImage(String)
        case text(String)
    }

    let content: Content
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let size: CGFloat
    let tint: Color?
    let isEnabled: Bool
    var isInteractive = true
    var isRepeatable = false
    var suppressesTap = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var repeatPressState = RepeatPressState.idle
    @State private var repeatTask: Task<Void, Never>?

    private let repeatMovementLimit: CGFloat = 10
    private let repeatInitialDelayNanoseconds: UInt64 = 350_000_000
    private let repeatIntervalNanoseconds: UInt64 = 50_000_000

    private enum RepeatPressState: Equatable {
        case idle
        case pressed
        case repeating
        case moved

        var suppressesTap: Bool {
            self == .repeating || self == .moved
        }
    }

    var body: some View {
        repeatAwareButton
            .onDisappear(perform: cancelRepeat)
    }

    @ViewBuilder
    private var repeatAwareButton: some View {
        if #available(iOS 17, *) {
            interactiveButton
                .onChange(of: repeatIsAllowed) { _, isAllowed in
                    if !isAllowed {
                        resetRepeatPress()
                    }
                }
        } else {
            interactiveButton
                .onChange(of: repeatIsAllowed) { isAllowed in
                    if !isAllowed {
                        resetRepeatPress()
                    }
                }
        }
    }

    @ViewBuilder
    private var interactiveButton: some View {
        let button = Button {
            guard isInteractive,
                  !suppressesTap,
                  !repeatPressState.suppressesTap else { return }
            action()
        } label: {
            buttonLabel
        }
        .buttonStyle(
            TerminalFloatingControlCircleButtonStyle(
                size: size,
                tint: tint,
                isInteractive: isInteractive
            )
        )
        .frame(width: size, height: size)
        .contentShape(Circle())
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)

        if isInteractive && isRepeatable {
            button.simultaneousGesture(repeatGesture)
        } else {
            button
        }
    }

    private var buttonLabel: some View {
        ZStack {
            buttonLabelContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(contentAnimation, value: content)
    }

    @ViewBuilder
    private var buttonLabelContent: some View {
        switch content {
        case .systemImage(let name):
            systemImage(name)
        case .text(let title):
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .id(content)
                .transition(contentTransition)
        }
    }

    @ViewBuilder
    private func systemImage(_ name: String) -> some View {
        if #available(iOS 18, *), !reduceMotion {
            symbol(name)
                .contentTransition(
                    .symbolEffect(
                        .replace.magic(fallback: .replace.downUp.byLayer)
                    )
                )
        } else if #available(iOS 17, *), !reduceMotion {
            symbol(name)
                .contentTransition(.symbolEffect(.replace.downUp.byLayer))
        } else {
            symbol(name)
                .id(name)
                .contentTransition(.opacity)
                .transition(contentTransition)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(
                .system(
                    size: size == TerminalFloatingControlLayout.radialMainButtonSize
                        ? 23
                        : 15,
                    weight: .semibold
                )
            )
    }

    private var repeatIsAllowed: Bool {
        isInteractive && isRepeatable && isEnabled
    }

    private var contentAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.1) : .smooth(duration: 0.32)
    }

    private var contentTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.68).combined(with: .opacity)
    }

    private var repeatGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                guard distance < repeatMovementLimit else {
                    repeatPressState = .moved
                    cancelRepeat()
                    return
                }
                guard repeatPressState == .idle else { return }
                repeatPressState = .pressed
                repeatTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: repeatInitialDelayNanoseconds)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, repeatPressState == .pressed else { return }
                    repeatPressState = .repeating
                    while !Task.isCancelled {
                        action()
                        do {
                            try await Task.sleep(nanoseconds: repeatIntervalNanoseconds)
                        } catch {
                            return
                        }
                    }
                }
            }
            .onEnded { _ in
                cancelRepeat()
                DispatchQueue.main.async {
                    repeatPressState = .idle
                }
            }
    }

    private func cancelRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func resetRepeatPress() {
        cancelRepeat()
        repeatPressState = .idle
    }
}
#endif
