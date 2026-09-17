import Foundation

/// Retains a bounded prefix. Continued output is drained without growing this buffer.
nonisolated struct RemoteProcessOutputBuffer: Sendable {
    let limit: Int
    private(set) var data = Data()
    private(set) var truncated = false

    mutating func append(_ bytes: Data) {
        let remaining = max(0, limit) - data.count
        let retained = min(remaining, bytes.count)
        data.append(bytes.prefix(retained))
        truncated = truncated || retained < bytes.count
    }
}
