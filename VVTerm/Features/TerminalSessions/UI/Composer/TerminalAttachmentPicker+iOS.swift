#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct TerminalAttachmentPicker: View {
    @ObservedObject var composer: TerminalComposerStore
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Color.clear
            .photosPicker(isPresented: isPresented(.photos), selection: $photos,
                          maxSelectionCount: TerminalAttachmentLimits.maximumCount,
                          selectionBehavior: .ordered, matching: .images)
            .fileImporter(isPresented: isPresented(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .failure(let error) = result, (error as? CocoaError)?.code == .userCancelled { return }
                composer.load { try await TerminalAttachmentLoader.files(result.get()) }
            }
            .onChange(of: photos) { selection in
                guard !selection.isEmpty else { return }
                photos = []
                composer.load {
                    var payloads: [TerminalAttachmentPayload] = []
                    for (index, item) in selection.enumerated() {
                        try Task.checkCancellation()
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw TerminalAttachmentError.unreadable
                        }
                        let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .image
                        payloads.append(TerminalAttachmentPayload(data: data, contentType: type,
                                                                 suggestedFilename: "photo-\(index + 1).\(type.preferredFilenameExtension ?? "img")"))
                        try TerminalAttachmentLimits.validate(payloads)
                    }
                    return payloads
                }
            }
            .onChange(of: composer.attachmentSource) { source in
                guard source == .paste else { return }
                composer.attachmentSource = nil
                let images = Clipboard.attachmentPayloads()
                let urls = (UIPasteboard.general.urls ?? []).filter(\.isFileURL)
                composer.load {
                    let files = try await TerminalAttachmentLoader.files(urls)
                    guard !images.isEmpty || !files.isEmpty else { throw TerminalAttachmentError.unreadable }
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

    static func menu(onSelect: @escaping (TerminalComposerStore.AttachmentSource) -> Void) -> UIMenu {
        UIMenu(children: TerminalComposerStore.AttachmentSource.allCases.map { source in
            let action = UIAction(title: source.title, image: UIImage(systemName: source.symbol)) { _ in onSelect(source) }
            action.accessibilityIdentifier = source.accessibilityIdentifier
            return action
        })
    }
}

extension TerminalComposerStore.AttachmentSource {
    var title: String {
        switch self {
        case .photos: String(localized: "Photos")
        case .files: String(localized: "Files")
        case .paste: String(localized: "Paste")
        }
    }
    var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        case .paste: "doc.on.clipboard"
        }
    }
    var accessibilityIdentifier: String { "vvterm.attachments.\(self)" }
}
#endif
