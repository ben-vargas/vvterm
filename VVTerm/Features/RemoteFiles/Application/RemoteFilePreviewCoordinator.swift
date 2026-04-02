import AVFoundation
import Foundation
import os.log

extension RemoteFileBrowserStore {
    func loadPreview(
        for entry: RemoteFileEntry,
        serverId: UUID,
        allowLargeDownloads: Bool = false
    ) async {
        guard let server = server(for: serverId) else { return }

        let currentState = state(for: serverId)
        if currentState.isLoadingViewer, currentState.selectedEntryPath == entry.path {
            return
        }
        if currentState.viewerPayload?.entry.path == entry.path,
           currentState.viewerPayload?.previewKind != .unavailable,
           !(currentState.viewerPayload?.requiresExplicitDownload == true && allowLargeDownloads) {
            return
        }

        if let fileSize = entry.size,
           fileSize > UInt64(Self.previewConfirmationBytes),
           !allowLargeDownloads {
            cleanupPreviewArtifact(for: currentState.viewerPayload)
            viewerRequestIDs.removeValue(forKey: serverId)
            updateState(for: serverId) { state in
                state.selectedEntryPath = entry.path
                state.isLoadingViewer = false
                state.viewerError = nil
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: .unavailable,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: String(
                        localized: "This file is larger than 1 MB. Download it first if you want to preview it."
                    ),
                    requiresExplicitDownload: true,
                    previewByteCount: fileSize
                )
            }
            return
        }

        let requestID = UUID()
        viewerRequestIDs[serverId] = requestID
        cleanupPreviewArtifact(for: currentState.viewerPayload)

        updateState(for: serverId) { state in
            state.selectedEntryPath = entry.path
            state.isLoadingViewer = true
            state.viewerError = nil
            state.viewerPayload = nil
        }

        do {
            let readLimit = min(Int(entry.size ?? UInt64(Self.defaultPreviewBytes)), Self.hardPreviewBytes)
            let effectiveReadLimit = max(Self.defaultPreviewBytes, readLimit)
            let data = try await withClient(for: server) { client in
                try await client.readFile(at: entry.path, maxBytes: effectiveReadLimit)
            }

            guard viewerRequestIDs[serverId] == requestID else { return }

            let previewData = data.prefix(Self.defaultPreviewBytes)
            let isTruncated = (entry.size.map { $0 > UInt64(Self.defaultPreviewBytes) } ?? false)
                || data.count > Self.defaultPreviewBytes
                || data.count >= Self.hardPreviewBytes
            let previewKind = RemoteFilePreviewDetector.previewKind(for: entry, data: previewData)
            let payload: RemoteFileViewerPayload

            switch previewKind {
            case .text:
                payload = RemoteFileViewerPayload(
                    previewKind: .text,
                    entry: entry,
                    textPreview: RemoteFilePreviewDetector.decodeTextPreview(from: previewData),
                    previewFileURL: nil,
                    isTruncated: isTruncated,
                    unavailableMessage: nil,
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            case .image, .video:
                let previewFileURL: URL?
                let unavailableMessage: String?

                if let fileSize = entry.size, fileSize > UInt64(Self.maxMediaPreviewBytes) {
                    previewFileURL = nil
                    unavailableMessage = String(
                        localized: "This file is too large to preview inline. Download it to inspect the full contents."
                    )
                } else {
                    let tempURL = try makePreviewFileURL(for: entry)
                    do {
                        try await withClient(for: server) { client in
                            try await client.downloadFile(at: entry.path, to: tempURL)
                        }
                        if await validateDownloadedPreview(at: tempURL, kind: previewKind) {
                            previewFileURL = tempURL
                            unavailableMessage = nil
                        } else {
                            previewFileURL = tempURL
                            unavailableMessage = String(
                                localized: "This file downloaded successfully, but macOS could not open it for inline preview."
                            )
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        throw error
                    }
                }

                payload = RemoteFileViewerPayload(
                    previewKind: previewFileURL == nil ? .unavailable : previewKind,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: previewFileURL,
                    isTruncated: false,
                    unavailableMessage: unavailableMessage,
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            case .unavailable:
                payload = RemoteFileViewerPayload(
                    previewKind: .unavailable,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: String(localized: "Inline preview is unavailable for this file."),
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            }

            updateState(for: serverId) { state in
                state.isLoadingViewer = false
                state.viewerError = nil
                state.viewerPayload = payload
            }
        } catch {
            guard viewerRequestIDs[serverId] == requestID else { return }
            logger.error("Remote file preview failed for \(entry.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: serverId) { state in
                state.isLoadingViewer = false
                state.viewerPayload = nil
                state.viewerError = RemoteFileBrowserError.map(error)
            }
        }
    }

    func clearViewer(serverId: UUID) {
        cleanupPreviewArtifact(for: state(for: serverId).viewerPayload)
        updateState(for: serverId) { state in
            state.selectedEntryPath = nil
            state.viewerPayload = nil
            state.viewerError = nil
            state.isLoadingViewer = false
        }
        viewerRequestIDs.removeValue(forKey: serverId)
    }

    private func makePreviewFileURL(for entry: RemoteFileEntry) throws -> URL {
        let previewsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VVTermRemoteFilePreviews", isDirectory: true)
        try FileManager.default.createDirectory(
            at: previewsDirectory,
            withIntermediateDirectories: true
        )

        let fileExtension = URL(fileURLWithPath: entry.name).pathExtension
        var url = previewsDirectory.appendingPathComponent(UUID().uuidString)
        if !fileExtension.isEmpty {
            url.appendPathExtension(fileExtension)
        }
        return url
    }

    func cleanupPreviewArtifact(for payload: RemoteFileViewerPayload?) {
        guard let previewFileURL = payload?.previewFileURL else { return }
        try? FileManager.default.removeItem(at: previewFileURL)
    }

    private func validateDownloadedPreview(at url: URL, kind: RemoteFilePreviewKind) async -> Bool {
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
