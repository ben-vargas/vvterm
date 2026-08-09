import Darwin
import Foundation
import Testing
@testable import VVTerm

@Suite
struct SSHSocketReadinessPollerTests {
    @Test
    func readySocketResumesBeforeDeadline() async throws {
        let pair = try SocketPair()
        let poller = SSHSocketReadinessPoller(label: "test.ssh-readiness.ready")

        let wait = Task {
            await poller.wait(
                fileDescriptor: pair.readDescriptor,
                events: Int16(POLLIN),
                timeoutMilliseconds: 500
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        try pair.signal()

        let startedAt = ContinuousClock.now
        await wait.value
        #expect(ContinuousClock.now - startedAt < .milliseconds(100))
    }

    @Test
    func cancellationResumesWaiter() async throws {
        let pair = try SocketPair()
        let poller = SSHSocketReadinessPoller(label: "test.ssh-readiness.cancel")
        let wait = Task {
            await poller.wait(
                fileDescriptor: pair.readDescriptor,
                events: Int16(POLLIN),
                timeoutMilliseconds: 1_000
            )
        }

        try await Task.sleep(for: .milliseconds(10))
        let startedAt = ContinuousClock.now
        wait.cancel()
        await wait.value

        #expect(ContinuousClock.now - startedAt < .milliseconds(100))
    }

    @Test
    func manySessionWaitsShareOneBoundedPollWindow() async throws {
        let sessionCount = 128
        let pairs = try (0..<sessionCount).map { _ in try SocketPair() }
        let poller = SSHSocketReadinessPoller(label: "test.ssh-readiness.many")
        let startedAt = ContinuousClock.now

        await withTaskGroup(of: Void.self) { group in
            for pair in pairs {
                group.addTask {
                    await poller.wait(
                        fileDescriptor: pair.readDescriptor,
                        events: Int16(POLLIN),
                        timeoutMilliseconds: 10
                    )
                }
            }
        }

        let elapsed = ContinuousClock.now - startedAt
        print("DEV334 socket-readiness sessions=\(sessionCount) elapsed=\(elapsed)")
        #expect(elapsed < .milliseconds(250))
    }
}

private nonisolated final class SocketPair: @unchecked Sendable {
    let readDescriptor: Int32
    private let writeDescriptor: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SocketPairError.creationFailed(errno)
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
    }

    deinit {
        Darwin.close(readDescriptor)
        Darwin.close(writeDescriptor)
    }

    func signal() throws {
        var byte: UInt8 = 1
        guard Darwin.write(writeDescriptor, &byte, 1) == 1 else {
            throw SocketPairError.writeFailed(errno)
        }
    }
}

private nonisolated enum SocketPairError: Error {
    case creationFailed(Int32)
    case writeFailed(Int32)
}
