#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalInputAccessoryViewTests {
    @Test
    func sharedCapsulesKeepNormalModifiersActionsAndHeight() throws {
        var keys: [TerminalKey] = []
        var dismissed = false
        let bar = TerminalInputAccessoryView(
            terminalOwner: nil,
            inputSnapshot: .init(profile: .defaultValue(lastWriterDeviceId: "test"),
                                 showsDismissKeyboardButton: true),
            onKey: { keys.append($0) }, onCustomAction: { _ in },
            onDismissKeyboard: { dismissed = true }
        )
        func button(_ suffix: String, in view: UIView) -> UIButton? {
            if let button = view as? UIButton,
               button.accessibilityIdentifier == "vvterm.keyboard.accessory.\(suffix)" { return button }
            return view.subviews.lazy.compactMap { button(suffix, in: $0) }.first
        }
        let ctrl = try #require(button("modifier.ctrl", in: bar))
        let tab = try #require(button("system.tab", in: bar))
        ctrl.sendActions(for: .touchUpInside)
        #expect(ctrl.accessibilityTraits.contains(.selected))
        tab.sendActions(for: .touchUpInside)
        #expect(keys.count == 1)
        guard case .modified(.tab, let mods) = keys.first else {
            Issue.record("Expected Ctrl+Tab")
            return
        }
        #expect(mods.contains(.ctrl))
        #expect(!ctrl.accessibilityTraits.contains(.selected))
        #expect(ctrl.configuration?.background.backgroundColor == TerminalAccessoryButtonStyle.configuration().background.backgroundColor)
        #expect(!bar.consumeModifiers().ctrl)
        #expect(tab.configuration?.background.backgroundInsets.top == 6)
        #expect(bar.intrinsicContentSize.height == 48)
        #expect(bar.systemLayoutSizeFitting(CGSize(width: 320, height: 0)).height == 48)
        try #require(button("hide", in: bar)).sendActions(for: .touchUpInside)
        #expect(dismissed)
    }
}
#endif
