import Foundation
import Testing
@testable import VVTerm

struct RemoteFilePreviewDetectorTests {
    @Test
    func textPreviewIsDetectedAndDecoded() {
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt")
        let data = Data("hello\nworld".utf8)

        #expect(RemoteFilePreviewDetector.previewKind(for: entry, data: data) == .text)
        #expect(RemoteFilePreviewDetector.decodeTextPreview(from: data) == "hello\nworld")
    }

    @Test
    func imageExtensionFallsBackToImagePreviewWhenDataIsBinary() {
        let entry = makeEntry(name: "photo.png", path: "/tmp/photo.png")
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])

        #expect(RemoteFilePreviewDetector.previewKind(for: entry, data: data) == .image)
    }

    @Test
    func binaryDataWithoutKnownExtensionIsUnavailable() {
        let entry = makeEntry(name: "blob", path: "/tmp/blob")
        let data = Data([0x00, 0xFF, 0x10, 0x80])

        #expect(RemoteFilePreviewDetector.previewKind(for: entry, data: data) == .unavailable)
        #expect(RemoteFilePreviewDetector.decodeTextPreview(from: data) == nil)
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
