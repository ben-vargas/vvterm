import Foundation

struct RemoteFileTransferLimits: Sendable {
    let maxDepth: Int
    let maxEntries: Int
    let maxEntriesPerDirectory: Int
    let maxFileBytes: UInt64
    let maxAggregateBytes: UInt64
    let maxElapsed: Duration

    static let standard = RemoteFileTransferLimits(
        maxDepth: 64,
        maxEntries: 10_000,
        maxEntriesPerDirectory: 2_000,
        maxFileBytes: 256 * 1_024 * 1_024,
        maxAggregateBytes: 1 * 1_024 * 1_024 * 1_024,
        maxElapsed: .seconds(600)
    )
}

struct RemoteFileTransferPlanNode: Sendable {
    let entry: RemoteFileEntry
    let children: [RemoteFileTransferPlanNode]

    var unitCount: Int {
        children.reduce(1) { $0 + $1.unitCount }
    }
}

struct RemoteFileTraversalBudget {
    private(set) var admittedEntries = 0
    let limits: RemoteFileTransferLimits
    private let deadline: ContinuousClock.Instant

    init(limits: RemoteFileTransferLimits = .standard) {
        self.limits = limits
        deadline = ContinuousClock.now.advanced(by: limits.maxElapsed)
    }

    mutating func admit(depth: Int) throws {
        try checkTime()
        guard depth <= limits.maxDepth,
              admittedEntries < limits.maxEntries else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        admittedEntries += 1
    }

    mutating func directoryReadLimit() throws -> Int {
        try checkTime()
        let remaining = limits.maxEntries - admittedEntries
        guard remaining > 0 else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        return min(remaining, limits.maxEntriesPerDirectory)
    }

    mutating func checkTime() throws {
        guard ContinuousClock.now < deadline else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
    }
}

struct RemoteFileTransferByteBudget {
    private(set) var consumedBytes: UInt64 = 0
    let limits: RemoteFileTransferLimits

    init(limits: RemoteFileTransferLimits = .standard) {
        self.limits = limits
    }

    func downloadLimit(reportedBytes: UInt64?) throws -> UInt64 {
        let remaining = limits.maxAggregateBytes - min(consumedBytes, limits.maxAggregateBytes)
        let limit = min(limits.maxFileBytes, remaining)
        guard limit > 0,
              reportedBytes.map({ $0 <= limit }) ?? true else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        return limit
    }

    mutating func record(_ byteCount: UInt64) throws {
        guard byteCount <= limits.maxFileBytes,
              byteCount <= limits.maxAggregateBytes - min(consumedBytes, limits.maxAggregateBytes) else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        consumedBytes += byteCount
    }
}
