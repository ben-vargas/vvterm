import AVFoundation
import Foundation
import ImageIO
import os.log

struct RemoteFilePreviewLoader {
    nonisolated init() {}

    func previewKind(for entry: RemoteFileEntry, data: Data) -> RemoteFilePreviewKind {
        RemoteFilePreviewDetector.previewKind(for: entry, data: data)
    }

    func decodeTextPreview(from data: Data) -> String? {
        RemoteFilePreviewDetector.decodeTextPreview(from: data)
    }

    func validateDownloadedPreview(
        at url: URL,
        kind: RemoteFilePreviewKind,
        logger: Logger
    ) async -> Bool {
        switch kind {
        case .text, .unavailable:
            return false
        case .image:
            return validateImage(at: url)
        case .video:
            let asset = AVURLAsset(url: url)
            do {
                let isPlayable = try await asset.load(.isPlayable)
                let hasProtectedContent = try await asset.load(.hasProtectedContent)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let duration = try await asset.load(.duration).seconds
                guard isPlayable, !hasProtectedContent, !videoTracks.isEmpty else { return false }
                for track in videoTracks {
                    let size = try await track.load(.naturalSize)
                    guard RemoteMediaPreviewPolicy.permits(
                        width: abs(Double(size.width)),
                        height: abs(Double(size.height)),
                        frameCount: 1,
                        durationSeconds: duration
                    ) else {
                        return false
                    }
                }
                return true
            } catch {
                logger.error("Failed to validate remote video preview [path: \(url.path, privacy: .private(mask: .hash))] [error: \(LogPrivacy.errorClass(error), privacy: .public)]")
                return false
            }
        }
    }

    private func validateImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            return false
        }
        return RemoteMediaPreviewPolicy.permits(
            width: width,
            height: height,
            frameCount: CGImageSourceGetCount(source)
        )
    }
}
