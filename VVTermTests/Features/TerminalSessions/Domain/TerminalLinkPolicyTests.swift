import Foundation
import Testing
@testable import VVTerm

struct TerminalLinkPolicyTests {
    @Test(arguments: ["https://example.com/pull/94?tab=files#L2", "http://localhost:8080/", "mailto:test@example.com", "https://example.com/a%20b", "file:///etc/passwd", "file://remote/tmp/a%20b"])
    func acceptsSupportedLinks(text: String) {
        #expect(TerminalLinkPolicy.destination(text)?.absoluteString == text)
    }

    @Test(arguments: ["", "/tmp/example", "javascript:alert(1)", "data:text/html,test", "ssh://example.com", "file:relative", "file:///tmp/a%00b", "file:///tmp/a?x", "https:///", "mailto:", "https://example.com/\nnext", "https://example.com/\u{202E}abc"])
    func rejectsInvalidOrUnsupportedLinks(text: String) {
        #expect(TerminalLinkPolicy.destination(text) == nil)
    }

    @Test
    func rejectsExcessiveInput() {
        #expect(TerminalLinkPolicy.destination("https://example.com/" + String(repeating: "a", count: TerminalLinkPolicy.maximumURLByteCount)) == nil)
    }

    @Test
    func nativeDecoderCopiesOnlyTheDeclaredBytes() {
        let url = "https://example.com/actual"
        let buffer = Array((url + "unrelated").utf8)
        let result = buffer.withUnsafeBufferPointer { bytes in
            let pointer = UnsafeRawPointer(bytes.baseAddress!).assumingMemoryBound(to: CChar.self)
            return GhosttyRuntime.linkDestination(ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, url: pointer, len: UInt(url.utf8.count)))
        }
        #expect(result?.absoluteString == url)
    }

    @Test
    func nativeDecoderRejectsInvalidLengthsAndEncoding() {
        #expect(GhosttyRuntime.linkDestination(ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: nil, len: 1)) == nil)
        var byte: CChar = -1
        withUnsafePointer(to: &byte) { pointer in
            for count in [UInt(0), UInt(1), UInt.max] {
                #expect(GhosttyRuntime.linkDestination(ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: pointer, len: count)) == nil)
            }
        }
    }
}
