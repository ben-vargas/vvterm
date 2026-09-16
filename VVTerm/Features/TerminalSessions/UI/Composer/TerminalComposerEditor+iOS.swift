#if os(iOS)
import SwiftUI
import UIKit

/// A native editor preserves text editing and IME behavior while routing file paste to attachments.
struct TerminalComposerEditor: UIViewRepresentable {
    @AppStorage(TerminalKeyboardOptions.preferenceKey) private var storedKeyboardOptions = 0
    @AppStorage(TerminalInputMode.chatAccessoryPreferenceKey) private var chatAccessoryEnabled = false
    @Binding var text: String
    let isActive: Bool
    let keyboard: TerminalKeyboardCoordinator
    let paneID: UUID
    var acceptsEdits = true
    var placeholder = String(localized: "Type anything")
    var showsContent = true
    var inputAccessory: () -> UIView? = { nil }
    let onPasteAttachments: ([TerminalAttachmentPayload], [URL]) -> Void

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.applyKeyboardOptions(.init(rawValue: storedKeyboardOptions))
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        let focusTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.focus(_:)))
        focusTap.cancelsTouchesInView = false
        focusTap.delegate = context.coordinator
        view.addGestureRecognizer(focusTap)
        view.keyboard = keyboard
        view.paneID = paneID
        view.accessibilityLabel = String(localized: "Prompt")
        view.accessibilityIdentifier = "vvterm.composer.text"
        view.placeholderText = placeholder
        view.showsContent = showsContent
        view.textColor = showsContent ? .label : .clear
        view.tintColor = acceptsEdits && showsContent ? nil : .clear
        view.acceptsEdits = acceptsEdits
        view.onPasteAttachments = onPasteAttachments
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        let accessory = chatAccessoryEnabled ? inputAccessory() : nil
        if view.inputAccessoryView !== accessory {
            view.inputAccessoryView = accessory
            if view.isFirstResponder { view.reloadInputViews() }
        }
        view.applyKeyboardOptions(.init(rawValue: storedKeyboardOptions))
        let returnsToEditing = showsContent && !view.showsContent
        view.placeholderText = placeholder
        view.showsContent = showsContent
        view.textColor = showsContent ? .label : .clear
        view.tintColor = acceptsEdits && showsContent ? nil : .clear
        view.acceptsEdits = acceptsEdits
        view.onPasteAttachments = onPasteAttachments
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.setNeedsLayout()
        let availabilityChanged = view.allowsComposerFocus != isActive
        view.allowsComposerFocus = isActive
        keyboard.registerComposerInput(view, for: paneID)
        if availabilityChanged || returnsToEditing { keyboard.composerInputAvailabilityDidChange() }
    }

    static func dismantleUIView(_ view: ComposerTextView, coordinator: Coordinator) {
        if let paneID = view.paneID { view.keyboard?.unregisterComposerInput(view, for: paneID) }
        view.resignFirstResponder()
        view.keyboard = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 22
        return CGSize(width: width, height: max(40, min(fitting.height, lineHeight * 5 + 20)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: TerminalComposerEditor
        init(_ parent: TerminalComposerEditor) { self.parent = parent }
        @objc func focus(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ComposerTextView else { return }
            view.focusFromTap(at: gesture.location(in: view))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            parent.isActive && parent.keyboard.isUserHidden
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            parent.acceptsEdits
        }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

final class ComposerTextView: UITextView, TerminalComposerInputSession {
    weak var keyboard: TerminalKeyboardCoordinator?
    var paneID: UUID?
    var allowsComposerFocus = false
    private var coordinatorAllowsFocus = false
    private var requestedCaretLocation: CGPoint?
    var isComposerFirstResponder: Bool { isFirstResponder }

    override var canBecomeFirstResponder: Bool { coordinatorAllowsFocus && allowsComposerFocus && super.canBecomeFirstResponder }

    func insertComposerText(_ text: String) {
        guard acceptsEdits else { return }
        insertText(text)
    }

    func preventComposerInputAcquisition() {
        // Navigation removes the view and releases UIKit input during dismantling.
        coordinatorAllowsFocus = false
        requestedCaretLocation = nil
    }

    func focusFromTap(at point: CGPoint) {
        requestedCaretLocation = point
        keyboard?.userRequestedShow()
    }

    func setComposerInput(active: Bool, softwareKeyboardHidden: Bool) {
        // UIKit can try to restore its prior responder; only an explicit tap may end browsing.
        coordinatorAllowsFocus = active && !softwareKeyboardHidden
        let enabled = active && allowsComposerFocus
        if isEditable != enabled { isEditable = enabled }
        // Browsing releases focus. Keep the field editable so a native tap can restore it.
        guard enabled, !softwareKeyboardHidden else {
            requestedCaretLocation = nil
            resignFirstResponder()
            return
        }
        if window?.isKeyWindow == true, !isFirstResponder { becomeFirstResponder() }
        if isFirstResponder, let point = requestedCaretLocation {
            requestedCaretLocation = nil
            if let position = closestPosition(to: point) {
                selectedTextRange = textRange(from: position, to: position)
            }
        }
    }

    var onPasteAttachments: (([TerminalAttachmentPayload], [URL]) -> Void)?
    var acceptsEdits = true
    var placeholderText = String(localized: "Type anything") {
        didSet {
            guard oldValue != placeholderText else { return }
            UIView.transition(with: placeholder, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
                              options: [.transitionCrossDissolve, .beginFromCurrentState]) {
                self.placeholder.text = self.placeholderText
            }
        }
    }
    var showsContent = true
    private let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configurePlaceholder()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePlaceholder()
    }

    private func configurePlaceholder() {
        placeholder.text = String(localized: "Type anything")
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        placeholder.isUserInteractionEnabled = false
        addSubview(placeholder)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.isHidden = !showsContent || !text.isEmpty
        placeholder.font = font
        let height = font?.lineHeight ?? 0
        let left = textContainerInset.left + textContainer.lineFragmentPadding
        placeholder.frame = CGRect(x: left, y: (bounds.height - height) / 2,
                                   width: max(0, bounds.width - left - textContainerInset.right), height: height)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { resignFirstResponder() }
        keyboard?.composerInputAvailabilityDidChange()
    }

    override func paste(_ sender: Any?) {
        guard acceptsEdits else { return }
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages || (pasteboard.urls ?? []).contains(where: \.isFileURL) {
            let images = Clipboard.attachmentPayloads()
            let urls = (pasteboard.urls ?? []).filter(\.isFileURL)
            onPasteAttachments?(images, urls)
            // Text in a mixed clipboard stays in the editable draft and is never submitted here.
            if let text = pasteboard.string,
               !urls.contains(where: { $0.absoluteString == text || $0.path == text }) {
                insertText(text)
            }
        } else {
            super.paste(sender)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)),
           UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs { return true }
        return super.canPerformAction(action, withSender: sender)
    }
}
#endif
