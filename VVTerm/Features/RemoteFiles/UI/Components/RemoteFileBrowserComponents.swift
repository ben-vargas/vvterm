import SwiftUI

#if os(macOS)
import AppKit
#endif

struct RemoteFileEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(24)
    }
}

struct RemoteFileLoadingState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(24)
    }
}

struct RemoteFileMessageRow: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct RemoteFileDropOverlay: View {
    var body: some View {
        #if os(macOS)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.06))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
            }
            .overlay {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    VStack(spacing: 4) {
                        Text(String(localized: "Drop Items Here"))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(String(localized: "Upload local files, move items on this server, or copy items from another server."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .padding(40)
            }
        #else
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(0.8),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 8])
                    )
            }
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    Text(String(localized: "Drop to Transfer"))
                        .font(.headline)

                    Text(String(localized: "Local files upload here. Remote items move here on the same server or copy here from another server."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
            }
        #endif
    }
}

struct RemoteFileTransferStatusView: View {
    let status: RemoteFileBrowserScreen.TransferStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if status.phase == .succeeded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 18, height: 18)

                Text(status.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)
            }

            Text(status.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if status.phase == .succeeded, let fileName = status.fileName, !fileName.isEmpty {
                Text(fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if status.phase == .succeeded, let filePath = status.filePath, !filePath.isEmpty {
                Text(filePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if let completedUnitCount = status.completedUnitCount,
               let totalUnitCount = status.totalUnitCount,
               totalUnitCount > 0 {
                ProgressView(value: Double(completedUnitCount), total: Double(totalUnitCount))
                    .tint(status.phase == .succeeded ? .green : .accentColor)

                Text(
                    String(
                        format: String(localized: "%lld of %lld items"),
                        Int64(completedUnitCount),
                        Int64(totalUnitCount)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            #if os(macOS)
            if status.phase == .succeeded, let fileURL = status.fileURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label(String(localized: "Show in Finder"), systemImage: "finder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            #endif
        }
        .padding(14)
        #if os(iOS)
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        .frame(width: 340, alignment: .leading)
        #endif
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
    }
}
