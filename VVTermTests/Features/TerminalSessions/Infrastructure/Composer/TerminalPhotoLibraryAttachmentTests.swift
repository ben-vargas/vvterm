#if os(iOS)
import CoreTransferable
import UniformTypeIdentifiers
import XCTest
@testable import VVTerm

final class TerminalPhotoLibraryAttachmentTests: XCTestCase {
    func testImportsPhotosAndVideosWithTheirBytesAndFileType() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, type) in [("clip.MOV", UTType.quickTimeMovie), ("clip.mp4", .mpeg4Movie), ("photo.png", .png)] {
            let url = directory.appendingPathComponent(name)
            let bytes = Data([1, 2, 3, 4])
            try bytes.write(to: url)
            let attachment = try await importFile(url, type: type)
            XCTAssertEqual(attachment.payload.suggestedFilename, name)
            XCTAssertEqual(attachment.payload.contentType, type)
            XCTAssertEqual(attachment.payload.mimeType, type.preferredMIMEType)
            XCTAssertEqual(attachment.payload.data, bytes)
        }
    }

    func testRejectsOversizedVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(TerminalAttachmentLimits.maximumBytes) + 1)
        try file.close()
        do {
            _ = try await importFile(url, type: .mpeg4Movie)
            XCTFail("A video above the attachment limit must fail")
        } catch {
            // CoreTransferable can wrap the loader's error at the provider boundary.
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    private func importFile(_ url: URL, type: UTType) async throws -> TerminalPhotoLibraryAttachment {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: TerminalPhotoLibraryAttachment.self) { result in
                continuation.resume(with: result)
            }
        }
    }
}
#endif
