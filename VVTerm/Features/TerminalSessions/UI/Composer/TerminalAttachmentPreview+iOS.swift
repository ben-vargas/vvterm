#if os(iOS)
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct TerminalAttachmentPreview: View {
    let attachment: TerminalAttachmentPayload
    let isUploading: Bool
    let remove: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .accessibilityIdentifier("vvterm.attachment.preview.\(attachment.suggestedFilename)")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.fill").font(.title)
                    Text(attachment.suggestedFilename).font(.caption).lineLimit(2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel(attachment.suggestedFilename)
        .overlay {
            if isUploading {
                ProgressView()
                    .tint(.white)
                    .padding(10)
                    .background(.black.opacity(0.65), in: Circle())
                    .accessibilityLabel(String(format: String(localized: "Uploading %@"), attachment.suggestedFilename))
                    .accessibilityIdentifier("vvterm.attachment.upload.\(attachment.suggestedFilename)")
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.65), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Remove attachment") + Text(": \(attachment.suggestedFilename)"))
            .accessibilityIdentifier("vvterm.attachment.remove.\(attachment.suggestedFilename)")
        }
        .task(id: attachment.id) {
            guard attachment.contentType.conforms(to: .image),
                  let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 312
                  ] as CFDictionary) else { return }
            thumbnail = UIImage(cgImage: image)
        }
    }
}
#endif
