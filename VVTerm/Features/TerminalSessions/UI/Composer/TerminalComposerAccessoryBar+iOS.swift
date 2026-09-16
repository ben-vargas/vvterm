#if os(iOS)
import UIKit

final class TerminalComposerAccessoryBar: TerminalAccessoryKeyRow {
    var onKey: (TerminalKey) -> Void = { _ in }
    var onCustomAction: (TerminalAccessoryCustomAction) -> Void = { _ in }
    private var items: [TerminalAccessoryResolvedItem]?
    private var repeatTimer: Timer?

    init() {
        super.init()
        accessibilityIdentifier = "vvterm.composer.accessory"
        scroll.accessibilityIdentifier = "vvterm.composer.accessory.keys"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeating() }
    }

    func apply(_ items: [TerminalAccessoryResolvedItem]) {
        guard self.items != items else { return }
        self.items = items
        stopRepeating()
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in items {
            switch item {
            case .system(let action):
                if let key = action.terminalKey {
                    let button = makeButton(title: action.toolbarTitle, icon: action.iconName,
                                            label: action.listTitle, id: "system.\(action.rawValue)")
                    if action.isRepeatable {
                        button.addAction(UIAction { [weak self] _ in self?.startRepeating(key) }, for: .touchDown)
                        button.addAction(UIAction { [weak self] _ in self?.stopRepeating() },
                                         for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
                        // VoiceOver activates a button without a touch-down event.
                        button.accessibilityAction = { [weak self] in self?.onKey(key) }
                    } else {
                        button.addAction(UIAction { [weak self] _ in self?.onKey(key) }, for: .primaryActionTriggered)
                    }
                    stack.addArrangedSubview(button)
                }
            case .custom(let action):
                let title = action.title.isEmpty ? action.kind.title : String(action.title.prefix(12))
                let button = makeButton(title: title, label: action.title, id: "custom.\(action.id)")
                button.addAction(UIAction { [weak self] _ in
                    self?.onCustomAction(action)
                }, for: .primaryActionTriggered)
                stack.addArrangedSubview(button)
            }
        }
    }

    private func makeButton(title: String, icon: String? = nil, label: String, id: String) -> ComposerAccessoryKeyButton {
        let button = ComposerAccessoryKeyButton(type: .system)
        TerminalAccessoryButtonStyle.apply(to: button, title: title, icon: icon)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "vvterm.composer.accessory.\(id)"
        return button
    }

    private func startRepeating(_ key: TerminalKey) {
        stopRepeating()
        onKey(key)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onKey(key) }
        }
        timer.fireDate = Date().addingTimeInterval(0.35)
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    isolated deinit { repeatTimer?.invalidate() }
}
private final class ComposerAccessoryKeyButton: UIButton {
    var accessibilityAction: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let accessibilityAction else { return super.accessibilityActivate() }
        accessibilityAction()
        return true
    }
}
#endif
