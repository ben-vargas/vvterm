import Foundation
import Testing
@testable import VVTerm

struct RemoteFileTemporaryStorageTests {
    @Test
    func previewFilesArePlacedInPreviewSubdirectoryAndKeepExtension() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "frame.mov", path: "/tmp/frame.mov")

        let url = try storage.makePreviewFileURL(for: entry)

        #expect(url.pathExtension == "mov")
        #expect(url.path.contains("/Previews/"))
    }

    @Test
    func removePreviewArtifactDeletesStoredFile() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "frame.mov", path: "/tmp/frame.mov")
        let previewURL = try storage.makePreviewFileURL(for: entry)
        try Data([0x01, 0x02]).write(to: previewURL)
        let payload = RemoteFileViewerPayload(
            previewKind: .video,
            entry: entry,
            textPreview: nil,
            previewFileURL: previewURL,
            isTruncated: false,
            unavailableMessage: nil,
            requiresExplicitDownload: false,
            previewByteCount: 2
        )

        storage.removePreviewArtifact(for: payload)

        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
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
}
