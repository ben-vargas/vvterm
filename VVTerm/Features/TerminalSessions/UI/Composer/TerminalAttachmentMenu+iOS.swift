#if os(iOS)
import SwiftUI
import UIKit

/// Both composer and terminal accessory use the same expanding attachment control.
struct TerminalAttachmentMenu: UIViewRepresentable {
    let onSelect: (TerminalComposerStore.AttachmentSource) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        if #available(iOS 26.0, *) { config = .glass() }
        else { config.background.visualEffect = UIBlurEffect(style: .systemMaterial) }
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        config.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24))
        config.baseForegroundColor = .label
        button.configuration = config
        button.accessibilityLabel = String(localized: "Attachments")
        button.accessibilityIdentifier = "vvterm.composer.attach"
        button.addAction(UIAction { [weak button, weak coordinator = context.coordinator] _ in
            guard let button, let coordinator else { return }
            coordinator.presentation.present(from: button) { coordinator.onSelect($0) }
        }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.onSelect = onSelect
        uiView.isEnabled = context.environment.isEnabled
        if !uiView.isEnabled { context.coordinator.presentation.dismiss() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }
    static func dismantleUIView(_ uiView: UIButton, coordinator: Coordinator) { coordinator.presentation.dismiss() }

    final class Coordinator {
        let presentation = TerminalAttachmentMenuPresentation()
        var onSelect: (TerminalComposerStore.AttachmentSource) -> Void
        init(onSelect: @escaping (TerminalComposerStore.AttachmentSource) -> Void) { self.onSelect = onSelect }
    }
}

@MainActor
final class TerminalAttachmentMenuPresentation {
    private var window: UIWindow?

    func present(from source: UIView, onSelect: @escaping (TerminalComposerStore.AttachmentSource) -> Void) {
        guard window == nil, let scene = source.window?.windowScene else { return }
        let controller = AttachmentPanelController(source: source, onSelect: onSelect) { [weak self] in self?.dismiss() }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert
        window.backgroundColor = .clear
        window.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
        window.rootViewController = controller
        self.window = window
        // Do not make this window key: the native editor must retain its keyboard.
        window.isHidden = false
    }

    func dismiss() {
        (window?.rootViewController as? AttachmentPanelController)?.restoreSource()
        window?.isHidden = true
        window = nil
    }

    isolated deinit { dismiss() }
}

private final class AttachmentPanelController: UIViewController {
    private weak var source: UIView?
    private let onSelect: (TerminalComposerStore.AttachmentSource) -> Void
    private let onDismiss: () -> Void
    private let panel = UIVisualEffectView()
    private let rows = UIStackView()
    private let scrollView = UIScrollView()
    private var animator: UIViewPropertyAnimator?
    private var initialBounds = CGRect.zero
    private var sourceFrame = CGRect.zero

    init(source: UIView, onSelect: @escaping (TerminalComposerStore.AttachmentSource) -> Void,
         onDismiss: @escaping () -> Void) {
        self.source = source
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let outside = UIButton(frame: view.bounds)
        outside.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outside.accessibilityLabel = String(localized: "Close")
        outside.accessibilityIdentifier = "vvterm.attachments.dismiss"
        outside.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        view.addSubview(outside)
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            panel.effect = glass
        } else {
            panel.effect = UIBlurEffect(style: .systemMaterial)
        }
        panel.clipsToBounds = true
        panel.layer.cornerCurve = .continuous
        panel.accessibilityIdentifier = "vvterm.attachments.panel"
        view.addSubview(panel)
        rows.axis = .vertical
        rows.distribution = .fillEqually
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        panel.contentView.addSubview(scrollView)
        scrollView.addSubview(rows)
        for source in TerminalComposerStore.AttachmentSource.allCases {
            let row = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = source.title
            config.image = source.appIcon
            config.imagePadding = 20
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
            config.baseForegroundColor = .label
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = UIFont.preferredFont(forTextStyle: .title2)
                return result
            }
            row.configuration = config
            row.contentHorizontalAlignment = .leading
            row.accessibilityIdentifier = source.accessibilityIdentifier
            row.addAction(UIAction { [weak self] _ in self?.close(selection: source) }, for: .touchUpInside)
            rows.addArrangedSubview(row)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDeactivated(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let source, source.window != nil else { onDismiss(); return }
        initialBounds = view.bounds
        sourceFrame = source.convert(source.bounds, to: view)
        let width = min(330, max(0, view.bounds.width - 24))
        let rowHeight = UIFontMetrics(forTextStyle: .title2).scaledValue(for: 76)
        let contentHeight = rowHeight * CGFloat(rows.arrangedSubviews.count) + 20
        let safeTop = view.safeAreaInsets.top + 8
        // Expand upward from the control. App windows cannot reliably cover
        // the system keyboard; every row must remain visible above it.
        let bottom = min(sourceFrame.maxY, view.bounds.height - view.safeAreaInsets.bottom - 8)
        let height = min(contentHeight, max(44, bottom - safeTop))
        let x = min(max(12, sourceFrame.minX), view.bounds.width - width - 12)
        let expanded = CGRect(x: x, y: max(safeTop, bottom - height), width: width, height: height)
        rows.frame = CGRect(x: 0, y: 10, width: width, height: contentHeight - 20)
        scrollView.contentSize = CGSize(width: width, height: contentHeight)
        rows.alpha = 0
        panel.frame = sourceFrame
        scrollView.frame = panel.bounds
        panel.layer.cornerRadius = min(sourceFrame.width, sourceFrame.height) / 2
        source.alpha = 0
        animate {
            self.panel.frame = expanded
            self.panel.layer.cornerRadius = 32
            self.rows.alpha = 1
        }
        UIAccessibility.post(notification: .layoutChanged, argument: rows.arrangedSubviews.first)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if initialBounds != .zero, initialBounds.size != view.bounds.size { onDismiss() }
    }

    func restoreSource() { source?.alpha = 1 }

    private func close(selection: TerminalComposerStore.AttachmentSource? = nil) {
        view.isUserInteractionEnabled = false
        animate {
            self.panel.frame = self.sourceFrame
            self.panel.layer.cornerRadius = min(self.sourceFrame.width, self.sourceFrame.height) / 2
            self.rows.alpha = 0
        } completion: { [weak self] in
            guard let self else { return }
            onDismiss()
            if let selection { onSelect(selection) }
            else { UIAccessibility.post(notification: .layoutChanged, argument: source) }
        }
    }

    private func animate(_ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        animator?.stopAnimation(true)
        if UIAccessibility.isReduceMotionEnabled {
            changes()
            completion?()
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.35, dampingRatio: 0.86, animations: changes)
        animator.addCompletion { _ in completion?() }
        self.animator = animator
        animator.startAnimation()
    }

    override func accessibilityPerformEscape() -> Bool { close(); return true }
    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === view.window?.windowScene else { return }
        onDismiss()
    }
    isolated deinit { animator?.stopAnimation(true); NotificationCenter.default.removeObserver(self) }
}

private extension TerminalComposerStore.AttachmentSource {
    var appIcon: UIImage? {
        let assetName: String?
        switch self {
        case .photos: assetName = "AttachmentPhotos"
        case .files: assetName = "AttachmentFiles"
        case .paste: assetName = nil
        }
        if let assetName, let image = UIImage(named: assetName) {
            let size = CGSize(width: 44, height: 44)
            return UIGraphicsImageRenderer(size: size).image { _ in
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12).addClip()
                image.draw(in: CGRect(origin: .zero, size: size))
            }.withRenderingMode(.alwaysOriginal)
        }
        guard let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)) else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44)).image { _ in
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 44, height: 44), cornerRadius: 12).fill()
            let scale = min(28 / image.size.width, 28 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.withTintColor(.label).draw(in: CGRect(x: (44 - size.width) / 2, y: (44 - size.height) / 2,
                                                      width: size.width, height: size.height))
        }.withRenderingMode(.alwaysOriginal)
    }
}
#endif
