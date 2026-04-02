import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFilePreviewCoordinatorTests {
    @Test
    func clearViewerRemovesPreviewArtifactAndResetsState() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temporaryStorage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let store = RemoteFileBrowserStore(
            defaults: makeDefaults(),
            temporaryStorage: temporaryStorage
        )
        let serverId = UUID()
        let entry = makeEntry(name: "preview.txt", path: "/tmp/preview.txt")
        let previewURL = try temporaryStorage.makePreviewFileURL(for: entry)
        try Data("preview".utf8).write(to: previewURL)

        store.updateState(for: serverId) { state in
            state.selectedEntryPath = entry.path
            state.viewerPayload = RemoteFileViewerPayload(
                previewKind: .text,
                entry: entry,
                textPreview: "preview",
                previewFileURL: previewURL,
                isTruncated: false,
                unavailableMessage: nil,
                requiresExplicitDownload: false,
                previewByteCount: 7
            )
            state.viewerError = .failed("stale")
            state.isLoadingViewer = true
        }

        store.clearViewer(serverId: serverId)

        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
        #expect(store.selectedEntryPath(for: serverId) == nil)
        #expect(store.viewerPayload(for: serverId) == nil)
        #expect(store.viewerError(for: serverId) == nil)
        #expect(!store.isLoadingViewer(for: serverId))
    }

    private func makeEntry(name: String, path: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: .file,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFilePreviewCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
