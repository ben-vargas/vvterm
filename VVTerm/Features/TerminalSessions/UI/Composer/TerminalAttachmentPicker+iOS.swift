#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct TerminalAttachmentPicker: View {
    @ObservedObject var composer: TerminalComposerStore
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [PhotosPickerItem] = []
    @State private var showsFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                PhotosPicker(selection: $photos, maxSelectionCount: TerminalAttachmentLimits.maximumCount,
                             selectionBehavior: .ordered, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("vvterm.attachments.photos")
                Button { showsFiles = true } label: {
                    Label("Files", systemImage: "folder")
                }
                .accessibilityIdentifier("vvterm.attachments.files")
                Button {
                    let images = Clipboard.attachmentPayloads()
                    let urls = (UIPasteboard.general.urls ?? []).filter(\.isFileURL)
                    composer.load {
                        let files = try await TerminalAttachmentLoader.files(urls)
                        guard !images.isEmpty || !files.isEmpty else { throw TerminalAttachmentError.unreadable }
                        return images + files
                    }
                    dismiss()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("vvterm.attachments.paste")
                if composer.mode == .direct {
                    Button("Cancel") { dismiss() }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
        }
        .padding(20)
        .frame(width: 320)
        .buttonStyle(.plain)
        .labelStyle(AttachmentSourceLabelStyle())
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                composer.load { try await TerminalAttachmentLoader.files(result.get()) }
                dismiss()
            }
            .onChange(of: photos) { selection in
                guard !selection.isEmpty else { return }
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
                dismiss()
            }
    }
}

private struct AttachmentSourceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 24) {
            configuration.icon
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: Circle())
            configuration.title.font(.title3)
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }
}

extension View {
    @ViewBuilder
    func attachmentPopoverAdaptation() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.popover)
        } else {
            self.presentationDetents([.height(220)])
        }
    }
}
#endif
