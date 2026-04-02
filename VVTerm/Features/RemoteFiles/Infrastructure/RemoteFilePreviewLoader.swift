import AVFoundation
import Foundation
import os.log

struct RemoteFilePreviewLoader {
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
            return FileManager.default.fileExists(atPath: url.path)
        case .video:
            let asset = AVURLAsset(url: url)
            do {
                let isPlayable = try await asset.load(.isPlayable)
                let hasProtectedContent = try await asset.load(.hasProtectedContent)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                return isPlayable && !hasProtectedContent && !videoTracks.isEmpty
            } catch {
                logger.error("Failed to validate remote video preview at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }
}
