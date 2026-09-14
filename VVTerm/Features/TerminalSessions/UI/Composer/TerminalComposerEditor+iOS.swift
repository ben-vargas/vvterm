#if os(iOS)
import SwiftUI
import UIKit

/// A native editor preserves text editing and IME behavior while routing file paste to attachments.
struct TerminalComposerEditor: UIViewRepresentable {
    @Binding var text: String
    let isActive: Bool
    let onPasteAttachments: ([TerminalAttachmentPayload], [URL]) -> Void

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.accessibilityLabel = String(localized: "Prompt")
        view.accessibilityIdentifier = "vvterm.composer.text"
        view.onPasteAttachments = onPasteAttachments
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteAttachments = onPasteAttachments
        if view.text != text, view.markedTextRange == nil { view.text = text }
        let shouldAcquire = isActive && !view.isEditable
        view.isEditable = isActive
        if shouldAcquire { view.becomeFirstResponder() }
        if !isActive { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 22
        return CGSize(width: width, height: max(44, min(fitting.height, lineHeight * 5 + 22)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TerminalComposerEditor
        init(_ parent: TerminalComposerEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

final class ComposerTextView: UITextView {
    var onPasteAttachments: (([TerminalAttachmentPayload], [URL]) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, isEditable { becomeFirstResponder() }
    }

    override func paste(_ sender: Any?) {
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
