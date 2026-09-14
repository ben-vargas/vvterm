#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalKeyboardAvoidanceViewModelTests {
    @Test
    func chatRestoresNativeKeyboardGeometryWithoutFrameNotification() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        let viewport = ComposerKeyboardViewport(frame: window.bounds)
        window.addSubview(viewport)
        viewport.guide.frameForTest = CGRect(x: 0, y: 500, width: 600, height: 200)
        let model = TerminalKeyboardAvoidanceViewModel()
        model.attachViewport(viewport)
        model.update(terminal: nil, scope: .container, isFocused: true,
                     preservesTerminalSize: false, keyboardFrame: nil,
                     usesSimulatedKeyboardGeometry: false, inputMode: .chat)
        #expect(model.layout.bottomInset > 0)
        model.update(terminal: nil, scope: .container, isFocused: true,
                     preservesTerminalSize: false, keyboardFrame: nil,
                     usesSimulatedKeyboardGeometry: false, inputMode: .direct)
        #expect(model.layout.bottomInset == 0)
        model.detach()
    }

    @Test(arguments: [false, true])
    func returningToRetainedViewportRestoresKeyboardLayout(preserves: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        let viewport = UIView(frame: window.bounds.insetBy(dx: 0, dy: 40))
        window.addSubview(viewport)
        let model = TerminalKeyboardAvoidanceViewModel()
        model.attachViewport(viewport)
        let keyboard = window.convert(
            CGRect(x: 0, y: 500, width: 600, height: 200),
            to: window.screen.coordinateSpace
        )
        model.update(terminal: nil, scope: .container, isFocused: false,
                     preservesTerminalSize: preserves, keyboardFrame: keyboard,
                     usesSimulatedKeyboardGeometry: true)
        #expect(model.layout.bottomInset == 160)

        // SwiftUI can retain the native view across disappearance. On return,
        // onAppear updates the model without another makeUIView call.
        model.detach()
        await drainMainQueue()
        #expect(model.layout.bottomInset == 0)
        viewport.frame.size.height -= 40
        model.update(terminal: nil, scope: .container, isFocused: false,
                     preservesTerminalSize: preserves, keyboardFrame: keyboard,
                     usesSimulatedKeyboardGeometry: true)
        #expect(model.layout.bottomInset == 120)
        #expect(model.layout.preservesTerminalSurfaceSize == preserves)
        model.detach()
    }

    @Test
    func dockedKeyboardUsesOwningWindowInMultitasking() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 30, y: 40, width: 600, height: 700)
        let viewport = UIView(frame: window.bounds.insetBy(dx: 0, dy: 40))
        window.addSubview(viewport)
        let model = TerminalKeyboardAvoidanceViewModel()
        model.attachViewport(viewport)
        let keyboardInWindow = CGRect(x: 0, y: 500, width: 600, height: 200)
        let keyboardOnScreen = window.convert(keyboardInWindow, to: window.screen.coordinateSpace)
        model.update(terminal: nil, scope: .container, isFocused: false,
                     preservesTerminalSize: false, keyboardFrame: keyboardOnScreen,
                     usesSimulatedKeyboardGeometry: true)
        #expect(model.layout.bottomInset == 160)
        model.detach()
    }

    @Test(arguments: [false, true])
    func realContainerShrinkAndEmptyKeyboardGeometryUseCurrentBounds(preserves: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let viewport = UIView(frame: window.convert(window.screen.bounds, from: window.screen.coordinateSpace))
        viewport.frame.size.height -= 120
        window.addSubview(viewport)
        try #require(viewport.window === window)
        let model = TerminalKeyboardAvoidanceViewModel()
        model.attachViewport(viewport)
        let screen = window.screen.bounds
        let docked = CGRect(x: screen.minX, y: screen.maxY - 300,
                            width: screen.width, height: 300)
        model.update(terminal: nil, scope: .container, isFocused: false, preservesTerminalSize: preserves,
                     keyboardFrame: docked, usesSimulatedKeyboardGeometry: true)
        #expect(model.layout.bottomInset == 180)
        viewport.frame.size.height -= 120
        model.scheduleRecalculation()
        await drainMainQueue()
        #expect(model.layout.bottomInset == 60)
        #expect(model.layout.preservesTerminalSurfaceSize == preserves)
        model.update(terminal: nil, scope: .container, isFocused: false, preservesTerminalSize: preserves,
                     keyboardFrame: nil, usesSimulatedKeyboardGeometry: true)
        #expect(model.layout.bottomInset == 0)
        #expect(model.layout.verticalOffset == 0)
        #expect(model.layout.preservesTerminalSurfaceSize == preserves)
        // Restoring docked mode must use the smaller container, not a saved maximum.
        model.update(terminal: nil, scope: .container, isFocused: false, preservesTerminalSize: preserves,
                     keyboardFrame: docked, usesSimulatedKeyboardGeometry: true)
        #expect(model.layout.bottomInset == 60)
        model.detach()
    }
}
private final class ComposerKeyboardGuide: UIKeyboardLayoutGuide {
    var frameForTest = CGRect.zero
    override var layoutFrame: CGRect { frameForTest }
}

private final class ComposerKeyboardViewport: UIView {
    let guide = ComposerKeyboardGuide()
    override var keyboardLayoutGuide: UIKeyboardLayoutGuide { guide }
}
#endif
