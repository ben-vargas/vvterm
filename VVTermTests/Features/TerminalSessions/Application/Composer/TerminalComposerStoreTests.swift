import Combine
import XCTest
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
@testable import VVTerm

@MainActor
final class TerminalComposerStoreTests: XCTestCase {
    func testTranscriptionStaysInChatDraftAndNeverSubmits() {
        let store = TerminalComposerStore(resolveRoute: { throw TerminalAttachmentError.unavailable })
        store.setMode(.chat)
        store.draft = "Review"
        store.appendTranscription("  these files  ")
        XCTAssertEqual(store.draft, "Review these files")
        store.appendTranscription("   ")
        XCTAssertEqual(store.draft, "Review these files")
        XCTAssertEqual(store.operation, .idle)
        store.setMode(.direct)
        store.appendTranscription("late result")
        XCTAssertEqual(store.draft, "Review these files")
    }

    func testPayloadPreservesTypeFilenameAndUsesSafeExtension() {
        let image = ClipboardImagePayload(data: Data([1, 2]), mimeType: "image/png", utType: UTType.png.identifier, suggestedExtension: "png")
        let attachment = TerminalAttachmentPayload(image: image)
        XCTAssertEqual(attachment.sizeBytes, 2)
        XCTAssertEqual(attachment.contentType, .png)
        XCTAssertEqual(attachment.suggestedExtension, "png")
        let file = TerminalAttachmentPayload(data: Data(), contentType: .pdf, suggestedFilename: "../../report.PDF")
        XCTAssertEqual(file.suggestedFilename, "report.PDF")
        XCTAssertEqual(file.suggestedExtension, "PDF")
        XCTAssertEqual(TerminalAttachmentPayload(data: Data(), contentType: .pdf, suggestedFilename: "").suggestedFilename, "attachment.pdf")
        XCTAssertNotEqual(attachment.id, TerminalAttachmentPayload(image: image).id)
    }

    func testFileLoadingPreservesNamesBytesAndOrderAndRejectsFolders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("report.pdf")
        let second = directory.appendingPathComponent("empty.txt")
        try Data([1, 2, 3]).write(to: first)
        try Data().write(to: second)
        let files = try await TerminalAttachmentLoader.files([first, second])
        XCTAssertEqual(files.map(\.suggestedFilename), ["report.pdf", "empty.txt"])
        XCTAssertEqual(files.map(\.sizeBytes), [3, 0])
        do {
            _ = try await TerminalAttachmentLoader.files([directory])
            XCTFail("Folder must fail")
        } catch { XCTAssertTrue(error is TerminalAttachmentError) }
    }

    #if os(iOS)
    func testPlaceholderUsesEditorFontAndStaysVerticallyCentered() {
        let editor = ComposerTextView(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        for size: CGFloat in [17, 23, 31] {
            editor.font = .systemFont(ofSize: size)
            editor.setNeedsLayout()
            editor.layoutIfNeeded()
            let placeholder = editor.subviews.compactMap { $0 as? UILabel }.first
            XCTAssertNotNil(placeholder)
            XCTAssertEqual(placeholder?.font, editor.font)
            XCTAssertEqual(placeholder?.frame.midY ?? -1, editor.bounds.midY, accuracy: 0.5)
        }
        editor.text = "Draft"
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        XCTAssertTrue(editor.subviews.compactMap { $0 as? UILabel }.first?.isHidden == true)
    }

    func testNativeEditorAcceptsFilePasteWithoutInsertingLocalPath() {
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        let url = URL(fileURLWithPath: "/tmp/composer-file.txt")
        UIPasteboard.general.url = url
        let editor = ComposerTextView()
        var files: [URL] = []
        editor.onPasteAttachments = { _, urls in files = urls }
        XCTAssertTrue(editor.canPerformAction(#selector(ComposerTextView.paste(_:)), withSender: nil))
        editor.paste(nil)
        XCTAssertEqual(files, [url])
        XCTAssertTrue(editor.text.isEmpty)
    }

    func testNativeClipboardKeepsImageOrderAndMixedText() throws {
        let pasteboard = UIPasteboard.general
        let previous = pasteboard.items
        defer { pasteboard.items = previous }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let images = [1, 2].map { width in
            UIGraphicsImageRenderer(size: CGSize(width: width, height: 1), format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
            }
        }
        pasteboard.items = [
            [UTType.png.identifier: try XCTUnwrap(images[0].pngData()), UTType.utf8PlainText.identifier: "draft"],
            [UTType.png.identifier: try XCTUnwrap(images[1].pngData())]
        ]
        let snapshot = Clipboard.snapshot()
        XCTAssertEqual(snapshot.text, "draft")
        XCTAssertEqual(snapshot.attachments.count, 2)
        XCTAssertEqual(snapshot.attachments.compactMap { UIImage(data: $0.data)?.size.width }, [1, 2])
    }
    #endif

    func testOversizedFileIsRejectedBeforeReadingBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(TerminalAttachmentLimits.maximumBytes) + 1)
        try file.close()
        do {
            _ = try await TerminalAttachmentLoader.files([url])
            XCTFail("Oversized file must fail")
        } catch { XCTAssertTrue(error is TerminalAttachmentError) }
    }

    func testClipboardSnapshotRetainsMultipleAttachmentsAndText() {
        let first = TerminalAttachmentPayload(data: Data([1]), contentType: .png, suggestedFilename: "one.png")
        let second = TerminalAttachmentPayload(data: Data([2]), contentType: .jpeg, suggestedFilename: "two.jpg")
        let snapshot = ClipboardSnapshot(text: "draft", attachments: [first, second])
        XCTAssertEqual(snapshot.attachments.map(\.id), [first.id, second.id])
        XCTAssertTrue(snapshot.hasText)
        XCTAssertTrue(snapshot.hasImage)
        XCTAssertEqual(snapshot.image?.data, first.data)
        XCTAssertEqual(snapshot.text, "draft")
    }

    func testCompositionKeepsMultilineTextAndStablePathOrder() {
        XCTAssertEqual(TerminalComposerStore.compose(text: "", pathTokens: []), "")
        XCTAssertEqual(TerminalComposerStore.compose(text: "hello\nworld", pathTokens: []), "hello\nworld")
        XCTAssertEqual(TerminalComposerStore.compose(text: "", pathTokens: ["'a b'", "c"]), "'a b' c")
        XCTAssertEqual(TerminalComposerStore.compose(text: "review", pathTokens: ["one"]), "review one")
    }

    func testSendUploadsInOrderAndSubmitsOnceThenClearsDraft() async throws {
        let fixture = Fixture()
        let store = fixture.store()
        XCTAssertEqual(store.mode, .direct)
        store.setMode(.chat)
        store.draft = "review\nthese"
        try store.add([payload("one.png"), payload("two.pdf")])
        await finish(store) { store.send() }
        XCTAssertEqual(fixture.uploaded, ["one.png", "two.pdf"])
        XCTAssertEqual(fixture.sent, ["review\nthese /tmp/one.png /tmp/two.pdf"])
        XCTAssertEqual(fixture.sentModes, [.chat])
        XCTAssertTrue(store.draft.isEmpty)
        XCTAssertTrue(store.attachments.isEmpty)
        XCTAssertTrue(fixture.removed.isEmpty)
    }

    func testPartialFailureKeepsWholeDraftAndCleansUpThenRetrySendsAll() async throws {
        let fixture = Fixture()
        fixture.failingName = "two.pdf"
        let store = fixture.store()
        store.setMode(.chat)
        store.draft = "review"
        try store.add([payload("one.png"), payload("two.pdf")])
        await finish(store) { store.send() }
        XCTAssertTrue(fixture.sent.isEmpty)
        XCTAssertEqual(fixture.removed, ["/tmp/one.png"])
        XCTAssertEqual(store.draft, "review")
        XCTAssertEqual(store.attachments.count, 2)
        guard case .failed(let message) = store.operation else { return XCTFail("Expected failure") }
        XCTAssertTrue(message.contains("two.pdf"))
        fixture.failingName = nil
        await finish(store) { store.send() }
        XCTAssertEqual(fixture.sent, ["review /tmp/one.png /tmp/two.pdf"])
    }

    func testDirectLoadSendsOnlyAttachmentsAndDoesNotEnter() async {
        let fixture = Fixture()
        let store = fixture.store()
        store.draft = "saved chat draft"
        let file = payload("file.txt")
        await finish(store) { store.load { [file] } }
        XCTAssertEqual(fixture.sent, ["/tmp/file.txt"])
        XCTAssertEqual(fixture.sentModes, [.direct])
        XCTAssertEqual(store.draft, "saved chat draft")
    }

    func testCancelDuringUploadNeverSubmitsLateResultAndCleansItUp() async throws {
        let began = expectation(description: "upload started")
        let cleaned = expectation(description: "upload cleaned")
        var continuation: CheckedContinuation<RemoteClipboardUpload, Never>?
        var sent = false
        let store = TerminalComposerStore(resolveRoute: {
            TerminalAttachmentRoute(upload: { _ in
                await withCheckedContinuation { continuation = $0; began.fulfill() }
            }, remove: { uploads in
                XCTAssertEqual(uploads.map(\.remotePath), ["/tmp/one"])
                cleaned.fulfill()
            }, submit: { _, _ in sent = true })
        })
        store.setMode(.chat)
        store.draft = "keep"
        try store.add([payload("one")])
        store.send()
        await fulfillment(of: [began], timeout: 2)
        store.cancel()
        continuation?.resume(returning: upload("one"))
        await fulfillment(of: [cleaned], timeout: 2)
        XCTAssertFalse(sent)
        XCTAssertEqual(store.draft, "keep")
        XCTAssertEqual(store.attachments.count, 1)
    }

    func testRouteRejectionDoesNotClearStateAndRemovalReleasesPayloads() async throws {
        let fixture = Fixture()
        fixture.rejectSubmit = true
        let store = fixture.store()
        store.setMode(.chat)
        store.draft = "keep"
        try store.add([payload("file")])
        await finish(store) { store.send() }
        XCTAssertEqual(store.attachments.count, 1)
        XCTAssertEqual(fixture.removed, ["/tmp/file"])
        store.tearDown()
        XCTAssertTrue(store.attachments.isEmpty)
        XCTAssertTrue(store.draft.isEmpty)
    }

    func testLimitAndRemovalAreAtomicAndTextOnlySendWorks() async throws {
        let fixture = Fixture()
        let store = fixture.store()
        store.setMode(.chat)
        let files = (0..<20).map { payload("\($0)") }
        try store.add(files)
        XCTAssertThrowsError(try store.add([payload("overflow")]))
        XCTAssertEqual(store.attachments.count, 20)
        store.removeAttachment(files[0].id)
        XCTAssertEqual(store.attachments.first?.suggestedFilename, "1")
        store.discardAttachments()
        store.draft = "hello"
        await finish(store) { store.send() }
        XCTAssertEqual(fixture.sent, ["hello"])
        XCTAssertTrue(fixture.uploaded.isEmpty)
    }

    private func finish(_ store: TerminalComposerStore, action: () -> Void) async {
        let done = expectation(description: "operation finished")
        var started = false
        var finished = false
        let subscription = store.$operation.sink { operation in
            switch operation {
            case .loading, .uploading: started = true
            case .idle, .failed:
                if started && !finished { finished = true; done.fulfill() }
            }
        }
        action()
        await fulfillment(of: [done], timeout: 3)
        subscription.cancel()
        // Direct import moves through idle before starting the upload.
        if store.isBusy { await finish(store, action: {}) }
    }

    private func payload(_ name: String) -> TerminalAttachmentPayload {
        TerminalAttachmentPayload(data: Data([1]), contentType: .data, suggestedFilename: name)
    }

    private func upload(_ name: String) -> RemoteClipboardUpload {
        RemoteClipboardUpload(remotePath: "/tmp/\(name)", pastedPathToken: "/tmp/\(name)", mimeType: "application/octet-stream", sizeBytes: 1)
    }

    @MainActor
    private final class Fixture {
        var uploaded: [String] = []
        var removed: [String] = []
        var sent: [String] = []
        var sentModes: [TerminalInputMode] = []
        var failingName: String?
        var rejectSubmit = false
        func store() -> TerminalComposerStore {
            TerminalComposerStore(resolveRoute: { [self] in
                TerminalAttachmentRoute(upload: { [self] attachment in
                    if attachment.suggestedFilename == failingName { throw TerminalAttachmentError.unreadable }
                    uploaded.append(attachment.suggestedFilename)
                    return RemoteClipboardUpload(remotePath: "/tmp/\(attachment.suggestedFilename)", pastedPathToken: "/tmp/\(attachment.suggestedFilename)", mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes)
                }, remove: { [self] uploads in removed += uploads.map(\.remotePath) }, submit: { [self] text, mode in
                    if rejectSubmit { throw TerminalAttachmentError.unavailable }
                    sent.append(text)
                    sentModes.append(mode)
                })
            })
        }
    }
}
