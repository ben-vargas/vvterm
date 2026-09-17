import Foundation
import Testing
@testable import VVTerm

struct RemoteProcessOutputBufferTests {
    @Test func separateStreamsRetainIndependentPrefixes() {
        var stdout = RemoteProcessOutputBuffer(limit: 3)
        var stderr = RemoteProcessOutputBuffer(limit: 2)
        stdout.append(Data("abcdef".utf8))
        stderr.append(Data("x".utf8))
        #expect(stdout.data == Data("abc".utf8))
        #expect(stdout.truncated)
        #expect(stderr.data == Data("x".utf8))
        #expect(!stderr.truncated)
        stdout.append(Data(repeating: 0, count: 32_768))
        #expect(stdout.data.count == 3)
    }

    @Test func boundarySizesDoNotOverflow() {
        for limit in [0, Int.max] {
            var buffer = RemoteProcessOutputBuffer(limit: limit)
            buffer.append(Data([1, 2]))
            #expect(buffer.data.count == (limit == 0 ? 0 : 2))
            #expect(buffer.truncated == (limit == 0))
        }
    }
}
