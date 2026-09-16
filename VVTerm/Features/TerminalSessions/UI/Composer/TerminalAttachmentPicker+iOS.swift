#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct TerminalAttachmentPicker: View {
    @ObservedObject var composer: TerminalComposerStore
    let onPasteText: (String) -> Void
    var onDismiss: () -> Void = {}
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Color.clear
            .fullScreenCover(isPresented: isPresented(.camera), onDismiss: onDismiss) {
                TerminalCameraCapture { result in
                    composer.attachmentSource = nil
                    if let result { composer.load { [try result.get()] } }
                }
            }
            .photosPicker(isPresented: isPresented(.photos), selection: $photos,
                          maxSelectionCount: TerminalAttachmentLimits.maximumCount,
                          selectionBehavior: .ordered, matching: .any(of: [.images, .videos]),
                          preferredItemEncoding: .current)
            .fileImporter(isPresented: isPresented(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .failure(let error) = result, (error as? CocoaError)?.code == .userCancelled { return }
                composer.load { try await TerminalAttachmentLoader.files(result.get()) }
            }
            .onChange(of: photos) { selection in
                guard !selection.isEmpty else { return }
                photos = []
                composer.load {
                    var payloads: [TerminalAttachmentPayload] = []
                    for item in selection {
                        try Task.checkCancellation()
                        guard let attachment = try await item.loadTransferable(type: TerminalPhotoLibraryAttachment.self) else {
                            throw TerminalAttachmentError.unreadable
                        }
                        payloads.append(attachment.payload)
                        try TerminalAttachmentLimits.validate(payloads)
                    }
                    return payloads
                }
            }
            .onChange(of: composer.attachmentSource) { source in
                if source == nil { onDismiss(); return }
                guard source == .paste else { return }
                composer.attachmentSource = nil
                let images = Clipboard.attachmentPayloads()
                let urls = (UIPasteboard.general.urls ?? []).filter(\.isFileURL)
                if let text = UIPasteboard.general.string,
                   !urls.contains(where: { $0.absoluteString == text || $0.path == text }) {
                    onPasteText(text)
                }
                guard !images.isEmpty || !urls.isEmpty else { return }
                composer.load {
                    let files = try await TerminalAttachmentLoader.files(urls)
                    return images + files
                }
            }
    }

    private func isPresented(_ source: TerminalComposerStore.AttachmentSource) -> Binding<Bool> {
        Binding(get: { composer.attachmentSource == source }, set: { presented in
            if presented { composer.attachmentSource = source }
            else if composer.attachmentSource == source { composer.attachmentSource = nil }
        })
    }


}

extension TerminalComposerStore.AttachmentSource {
    var title: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .photos: String(localized: "Photos")
        case .files: String(localized: "Files")
        case .paste: String(localized: "Paste")
        }
    }
    var symbol: String {
        switch self {
        case .camera: "camera"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        case .paste: "doc.on.clipboard"
        }
    }
    var accessibilityIdentifier: String { "vvterm.attachments.\(self)" }
}
#endif
