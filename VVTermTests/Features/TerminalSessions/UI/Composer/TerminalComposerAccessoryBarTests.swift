#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalComposerAccessoryBarTests {
    @Test
    func chatHidesModifiersAndPreservesConfiguredActions() throws {
        let bar = TerminalComposerAccessoryBar()
        let command = TerminalAccessoryCustomAction(title: "Insert", kind: .command, commandContent: "hello")
        let shortcut = TerminalAccessoryCustomAction(title: "Shortcut", kind: .shortcut, shortcutKey: .a,
                                                     shortcutModifiers: .init(control: true, alternate: true, command: true, shift: true))
        let items: [TerminalAccessoryResolvedItem] = [.system(.commandModifier), .system(.tab), .custom(command), .custom(shortcut)]
        bar.apply(items)
        func identifiers(in view: UIView) -> [String] {
            [view.accessibilityIdentifier].compactMap { $0 } + view.subviews.flatMap { identifiers(in: $0) }
        }
        let ids = identifiers(in: bar)
        for suffix in ["modifier.ctrl", "modifier.alt", "modifier.shift", "system.commandModifier"] {
            #expect(!ids.contains("vvterm.composer.accessory.\(suffix)"))
        }
        var keys: [TerminalKey] = []
        var actions: [TerminalAccessoryCustomAction] = []
        bar.onKey = { keys.append($0) }
        bar.onCustomAction = { actions.append($0) }
        let tab = try button("system.tab", in: bar)
        tab.sendActions(for: .primaryActionTriggered)
        #expect(keys.count == 1)
        guard case .tab = keys[0] else {
            Issue.record("Expected Tab")
            return
        }
        try button("custom.\(command.id)", in: bar).sendActions(for: .primaryActionTriggered)
        try button("custom.\(shortcut.id)", in: bar).sendActions(for: .primaryActionTriggered)
        #expect(actions == [command, shortcut])
        // Applying unchanged settings must preserve the native button and its interaction.
        bar.apply(items)
        #expect(try button("system.tab", in: bar) === tab)
    }

    @Test
    func repeatableTapAndAccessibilityActivationEachSendOneKey() throws {
        let bar = TerminalComposerAccessoryBar()
        bar.apply([.system(.backspace)])
        var keys: [TerminalKey] = []
        bar.onKey = { keys.append($0) }
        let backspace = try button("system.backspace", in: bar)
        backspace.sendActions(for: .touchDown)
        backspace.sendActions(for: [.touchUpInside, .primaryActionTriggered])
        #expect(keys.count == 1)
        #expect(backspace.accessibilityActivate())
        #expect(keys.count == 2)
    }

    @Test
    func holdRepeatsAndCancelStopsIt() async throws {
        let bar = TerminalComposerAccessoryBar()
        bar.apply([.system(.backspace)])
        var count = 0
        bar.onKey = { _ in count += 1 }
        let backspace = try button("system.backspace", in: bar)
        backspace.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(500))
        #expect(count > 1)
        backspace.sendActions(for: .touchCancel)
        let stoppedCount = count
        try await Task.sleep(for: .milliseconds(100))
        #expect(count == stoppedCount)
    }

    @Test
    func fadesFollowOverflowOnInitialLayoutScrollAndResize() throws {
        let bar = TerminalComposerAccessoryBar()
        bar.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        bar.apply([.system(.escape), .system(.tab), .system(.arrowUp), .system(.arrowDown),
                   .system(.arrowLeft), .system(.arrowRight), .system(.backspace)])
        bar.layoutIfNeeded()
        let scroll = try #require(bar.subviews.compactMap { $0 as? UIScrollView }.first)
        let fades = bar.subviews.compactMap { $0 as? UIVisualEffectView }
        #expect(fades.count == 2)
        #expect(scroll.contentInset.left == 24)
        #expect(scroll.contentInset.right == 24)
        let mask = try #require(bar.layer.mask as? CAGradientLayer)
        #expect(mask.frame.minX == 0)
        #expect(mask.frame.width == bar.bounds.width)
        #expect(fades[0].frame.minX == 0)
        #expect(fades[1].frame.maxX == bar.bounds.width)
        #expect(fades[0].isHidden)
        #expect(!fades[1].isHidden)
        scroll.contentOffset.x = scroll.contentSize.width + scroll.adjustedContentInset.right - scroll.bounds.width
        #expect(!fades[0].isHidden)
        #expect(fades[1].isHidden)
        bar.frame.size.width = 1000
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(fades[0].isHidden)
        #expect(fades[1].isHidden)
    }

    private func button(_ id: String, in view: UIView) throws -> UIButton {
        func find(in view: UIView) -> UIButton? {
            if let button = view as? UIButton,
               button.accessibilityIdentifier == "vvterm.composer.accessory.\(id)" { return button }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return try #require(find(in: view))
    }
}
#endif
