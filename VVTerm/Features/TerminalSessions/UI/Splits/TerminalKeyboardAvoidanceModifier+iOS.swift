#if os(iOS)
import Combine
import SwiftUI
import UIKit

enum TerminalKeyboardLayoutScope {
    case container
    case pane
}

extension View {
    func terminalCommandFocusValues(
        activeServerId: UUID?,
        activePaneId: UUID?,
        splitActions: TerminalSplitActions?
    ) -> some View {
        self
    }

    func terminalKeyboardAvoidance(
        focusedPaneId: UUID?,
        paneIds: [UUID],
        terminalSurfaceChange: TerminalSurfaceStoreChange?,
        terminalProvider: @escaping (UUID) -> GhosttyTerminalView?,
        keyboardCoordinator: TerminalKeyboardCoordinator,
        scope: TerminalKeyboardLayoutScope = .pane,
        enabledOverride: Bool? = nil,
        usesSimulatedKeyboardGeometry: Bool = false
    ) -> some View {
        modifier(TerminalKeyboardAvoidanceModifier(
            focusedPaneId: focusedPaneId,
            paneIds: paneIds,
            terminalSurfaceChange: terminalSurfaceChange,
            terminalProvider: terminalProvider,
            keyboardCoordinator: keyboardCoordinator,
            scope: scope,
            enabledOverride: enabledOverride,
            usesSimulatedKeyboardGeometry: usesSimulatedKeyboardGeometry
        ))
    }
}

private struct TerminalKeyboardAvoidanceModifier: ViewModifier {
    let focusedPaneId: UUID?
    let paneIds: [UUID]
    let terminalSurfaceChange: TerminalSurfaceStoreChange?
    let terminalProvider: (UUID) -> GhosttyTerminalView?
    @ObservedObject var keyboardCoordinator: TerminalKeyboardCoordinator
    let scope: TerminalKeyboardLayoutScope
    let enabledOverride: Bool?
    let usesSimulatedKeyboardGeometry: Bool

    @AppStorage(TerminalDefaults.preserveTerminalSizeForKeyboardKey) private var storedEnabled = false
    @StateObject private var model = TerminalKeyboardAvoidanceViewModel()

    private var preservesTerminalSize: Bool {
        (enabledOverride ?? storedEnabled) && keyboardCoordinator.activeInputMode == .direct
    }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let contentHeight = max(geometry.size.height - model.layout.bottomChromeInset, 0)
            let visibleHeight = max(contentHeight - model.layout.bottomInset,
                                    min(contentHeight, 1))
            content
                .frame(
                    width: geometry.size.width,
                    height: scope == .pane || preservesTerminalSize ? contentHeight : visibleHeight,
                    alignment: .topLeading
                )
                .offset(y: model.layout.verticalOffset)
                // Clip after moving the full-size surface, inside stationary
                // pane chrome. Each split keeps its own viewport and grid.
                .frame(height: visibleHeight, alignment: .topLeading)
                .clipped()
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background {
                    TerminalKeyboardViewportObserver(model: model)
                }
        }
        .modifier(TerminalKeyboardSafeAreaModifier(isEnabled: scope == .container))
        .animation(nil, value: model.layout)
        .onAppear(perform: refresh)
        .onDisappear { model.detach() }
        .onChange(of: keyboardCoordinator.activeInputMode) { _ in refresh() }
        .onChange(of: preservesTerminalSize) { _ in refresh() }
        .onChange(of: focusedPaneId) { _ in refresh() }
        .onChange(of: terminalSurfaceChange) { _ in refresh() }
        .onChange(of: keyboardCoordinator.softwareKeyboardEndFrame) { _ in refresh() }
    }

    private func refresh() {
        model.update(
            terminal: (focusedPaneId ?? paneIds.first).flatMap(terminalProvider),
            scope: scope,
            isFocused: focusedPaneId != nil,
            preservesTerminalSize: preservesTerminalSize,
            keyboardFrame: keyboardCoordinator.softwareKeyboardEndFrame,
            usesSimulatedKeyboardGeometry: usesSimulatedKeyboardGeometry,
            inputMode: keyboardCoordinator.activeInputMode
        )
    }
}

private struct TerminalKeyboardViewportObserver: UIViewRepresentable {
    let model: TerminalKeyboardAvoidanceViewModel

    func makeUIView(context: Context) -> TerminalKeyboardViewportView {
        let view = TerminalKeyboardViewportView()
        view.onLayout = { [weak model] in model?.scheduleRecalculation() }
        model.attachViewport(view)
        return view
    }

    func updateUIView(_ view: TerminalKeyboardViewportView, context: Context) {}
}

private final class TerminalKeyboardViewportView: UIView {
    var onLayout: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        keyboardLayoutGuide.followsUndockedKeyboard = false
        if #available(iOS 17.0, *) {
            keyboardLayoutGuide.usesBottomSafeArea = false
        }
        let probe = UIView()
        probe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(probe)
        NSLayoutConstraint.activate([
            probe.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            probe.leadingAnchor.constraint(equalTo: leadingAnchor),
            probe.widthAnchor.constraint(equalToConstant: 0),
            probe.heightAnchor.constraint(equalToConstant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayout?()
    }
}
#endif
