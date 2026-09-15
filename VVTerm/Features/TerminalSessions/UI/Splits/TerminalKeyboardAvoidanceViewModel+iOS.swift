#if os(iOS)
import Combine
import UIKit

@MainActor
final class TerminalKeyboardAvoidanceViewModel: ObservableObject {
    @Published private(set) var layout = TerminalKeyboardAvoidancePolicy.Layout.unobstructed
    private weak var terminal: GhosttyTerminalView?
    private weak var viewport: UIView?
    private var scope = TerminalKeyboardLayoutScope.pane
    private var isFocused = false
    private var preservesTerminalSize = false
    private var keyboardFrame: CGRect?
    private var usesSimulatedKeyboardGeometry = false
    private var inputMode = TerminalInputMode.direct
    private var userHidKeyboard = false
    private var sceneIsActive = true

    func update(
        terminal newTerminal: GhosttyTerminalView?,
        scope: TerminalKeyboardLayoutScope,
        isFocused: Bool,
        preservesTerminalSize: Bool,
        keyboardFrame: CGRect?,
        usesSimulatedKeyboardGeometry: Bool,
        inputMode: TerminalInputMode = .direct,
        userHidKeyboard: Bool = false,
        sceneIsActive: Bool = true
    ) {
        if terminal !== newTerminal || self.scope != scope {
            detachTerminal()
            terminal = newTerminal
            self.scope = scope
            switch scope {
            case .pane:
                newTerminal?.onKeyboardAvoidanceCursorRectChange = { [weak self] _ in
                    self?.recalculate()
                }
            case .container:
                newTerminal?.onKeyboardAvoidanceAccessoryFrameChange = { [weak self] in
                    self?.scheduleRecalculation()
                }
            }
        }
        self.inputMode = inputMode
        self.userHidKeyboard = userHidKeyboard
        self.sceneIsActive = sceneIsActive
        self.isFocused = isFocused
        self.preservesTerminalSize = preservesTerminalSize
        self.keyboardFrame = keyboardFrame
        self.usesSimulatedKeyboardGeometry = usesSimulatedKeyboardGeometry
        #if DEBUG
        if scope == .pane {
            terminal?.keyboardAvoidancePreservesTerminalSize = preservesTerminalSize
        }
        #endif
        recalculate()
    }

    func attachViewport(_ viewport: UIView) {
        self.viewport = viewport
        scheduleRecalculation()
    }

    func scheduleRecalculation() {
        // UIKit can notify from inside layout or responder updates. Read the
        // current stationary geometry after that update, never a saved frame.
        DispatchQueue.main.async { [weak self] in self?.recalculate() }
    }

    func detach() {
        detachTerminal()
        // Disappearance does not end the native view's lifetime. Keep its weak
        // reference so onAppear can refresh a retained view without makeUIView.
        // Clear the frame so already queued layout work cannot restore it.
        keyboardFrame = nil
        layout = .unobstructed
    }

    private func detachTerminal() {
        switch scope {
        case .pane:
            terminal?.onKeyboardAvoidanceCursorRectChange = nil
            #if DEBUG
            terminal?.keyboardAvoidancePreservesTerminalSize = false
            #endif
        case .container:
            terminal?.onKeyboardAvoidanceAccessoryFrameChange = nil
        }
        terminal = nil
    }

    private func recalculate() {
        guard inputMode != .chat || sceneIsActive else { return }
        guard let viewport, let window = viewport.window else { return }
        let frame = viewport.convert(viewport.bounds, to: window)
        guard TerminalKeyboardAvoidancePolicy.isValid(frame) else { return }
        let bottomClearance = inputMode == .chat && userHidKeyboard
            ? min(window.safeAreaInsets.bottom, 20) : window.safeAreaInsets.bottom
        let bottomChromeInset = scope == .container
            ? min(max(frame.maxY - (window.bounds.maxY - bottomClearance), 0), frame.height)
            : 0
        var contentFrame = frame
        contentFrame.size.height -= bottomChromeInset
        let keyboardInWindow = keyboardFrame.map {
            window.convert($0, from: window.screen.coordinateSpace)
        }
        let observedGeometry = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: window.bounds,
            terminalFrame: contentFrame,
            keyboardFrame: keyboardInWindow
        )
        let geometry: TerminalKeyboardAvoidancePolicy.KeyboardGeometry
        let useNativeGuide: Bool
        if case .docked = observedGeometry { useNativeGuide = true }
        else { useNativeGuide = inputMode == .chat }
        if inputMode == .chat, userHidKeyboard {
            // A dismissed iPad keyboard can leave its native guide at the old height.
            geometry = .hidden
        } else if useNativeGuide, !usesSimulatedKeyboardGeometry {
            // The default native guide tracks docked obstruction only. Hidden
            // safe-area height is not a keyboard. Chat also reads this guide after
            // app activation, when UIKit can restore the keyboard without a frame notification.
            let guide = viewport.keyboardLayoutGuide.layoutFrame
            let dockedFrame = viewport.convert(guide, to: window)
            let safeAreaBottom = window.bounds.maxY - window.safeAreaInsets.bottom
            let hiddenInset = max(frame.maxY - safeAreaBottom, 0)
            geometry = TerminalKeyboardAvoidancePolicy.isValid(dockedFrame)
                && guide.minY < viewport.bounds.maxY - hiddenInset
                ? .docked(frame: dockedFrame) : .hidden
        } else {
            geometry = observedGeometry
        }
        let accessory = scope == .container ? terminal?.keyboardAvoidanceAccessoryFrame().map {
            window.convert($0, from: window.screen.coordinateSpace)
        } : nil
        // The cursor is local to this pane. Do not convert through the shifted
        // terminal view: layout may not yet have applied the previous offset.
        let cursor = scope == .pane && isFocused
            ? (terminal?.keyboardAvoidanceCursorRect() ?? .zero)
                .offsetBy(dx: frame.minX, dy: frame.minY)
            : .zero
        var next = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: preservesTerminalSize,
            geometry: geometry,
            terminalFrame: contentFrame,
            cursorFrame: cursor,
            accessoryFrame: accessory
        )
        next.bottomChromeInset = bottomChromeInset
        // The container resizes the split tree once when the option is off.
        // Individual panes only clip and move preserved content when it is on.
        if scope == .pane, !preservesTerminalSize { next = .unobstructed }
        if layout != next {
            terminal?.logKeyboardLifecycle(
                "viewport.layout",
                detail: "scope=\(scope) container=\(frame) chrome=\(bottomChromeInset) keyboard=\(geometry) accessory=\(String(describing: accessory)) inset=\(next.bottomInset) offset=\(next.verticalOffset)"
            )
            layout = next
        }
    }
}

#endif
