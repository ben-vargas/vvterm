import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileTransferCoordinatorTests {
    @Test
    func deleteDirectoryRecursivelyRemovesNestedContentsBeforeParent() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let service = RecordingRemoteFileService(
            directoryContents: [
                "/root/.vivyterm": [
                    makeEntry(name: "cache", path: "/root/.vivyterm/cache", type: .directory),
                    makeEntry(name: "config.json", path: "/root/.vivyterm/config.json", type: .file),
                    makeEntry(name: "current", path: "/root/.vivyterm/current", type: .symlink)
                ],
                "/root/.vivyterm/cache": [
                    makeEntry(name: "index.db", path: "/root/.vivyterm/cache/index.db", type: .file)
                ]
            ]
        )

        try await store.deleteDirectoryRecursively(at: "/root/.vivyterm", using: service)

        #expect(service.operations == [
            .deleteFile("/root/.vivyterm/cache/index.db"),
            .deleteDirectory("/root/.vivyterm/cache"),
            .deleteFile("/root/.vivyterm/config.json"),
            .deleteFile("/root/.vivyterm/current"),
            .deleteDirectory("/root/.vivyterm")
        ])
    }

    @Test
    func transferPlanRejectsChildOutsideListedDirectory() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let root = makeEntry(name: "root", path: "/root", type: .directory)
        let service = RecordingRemoteFileService(
            directoryContents: [
                "/root": [makeEntry(name: "escape.txt", path: "/outside/escape.txt")]
            ]
        )
        var budget = RemoteFileTraversalBudget()

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeRemoteTransferPlan(
                for: root,
                using: service,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &budget
            )
        }
    }

    @Test
    func transferPlanDoesNotFollowDirectorySymlink() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let link = makeEntry(name: "linked", path: "/root/linked", type: .symlink)
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            statEntries: [
                "/root/linked": makeEntry(
                    name: "target",
                    path: "/outside/target",
                    type: .directory
                )
            ]
        )
        var budget = RemoteFileTraversalBudget()

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeRemoteTransferPlan(
                for: link,
                using: service,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &budget
            )
        }
        #expect(service.listedPaths.isEmpty)
    }

    @Test
    func transferPlanEnforcesDepthLimit() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let root = makeEntry(name: "root", path: "/root", type: .directory)
        let child = makeEntry(name: "child", path: "/root/child", type: .directory)
        let grandchild = makeEntry(
            name: "grandchild",
            path: "/root/child/grandchild",
            type: .directory
        )
        let service = RecordingRemoteFileService(
            directoryContents: [
                "/root": [child],
                "/root/child": [grandchild]
            ]
        )
        var budget = RemoteFileTraversalBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 10,
                maxEntriesPerDirectory: 10,
                maxFileBytes: 10,
                maxAggregateBytes: 10,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 2
            )
        )

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeRemoteTransferPlan(
                for: root,
                using: service,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &budget
            )
        }
    }

    @Test
    func boundedDownloadRemovesOversizedFallbackFile() async throws {
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data(repeating: 0x41, count: 5)
        )
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-bounded-download-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: localURL) }

        await #expect(throws: RemoteFileBrowserError.self) {
            try await service.downloadFile(at: "/remote/file", to: localURL, maxBytes: 4)
        }
        #expect(!FileManager.default.fileExists(atPath: localURL.path))
    }

    @Test
    func downloadLimitUsesDeclaredSizeInsteadOfTheAbsoluteCap() throws {
        let budget = RemoteFileTransferByteBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 1,
                maxEntriesPerDirectory: 1,
                maxFileBytes: 100,
                maxAggregateBytes: 200,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 20
            )
        )

        #expect(
            try budget.downloadLimit(reportedBytes: 7, availableCapacity: 200) == 7
        )
    }

    @Test
    func downloadLimitKeepsTheFreeSpaceReserve() {
        let budget = RemoteFileTransferByteBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 1,
                maxEntriesPerDirectory: 1,
                maxFileBytes: 100,
                maxAggregateBytes: 200,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 20
            )
        )

        #expect(throws: RemoteFileBrowserError.self) {
            try budget.downloadLimit(reportedBytes: 11, availableCapacity: 30)
        }
    }

    @Test
    func validatedRemoteNameTrimsWhitespace() throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())

        let result = try store.validatedRemoteName("  notes.txt \n")

        #expect(result == "notes.txt")
    }

    @Test
    func validatedRemoteNameRejectsSlashSeparatedPaths() {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())

        #expect(throws: RemoteFileBrowserError.self) {
            try store.validatedRemoteName("nested/path.txt")
        }
    }

    @Test
    func uniqueTransferEntriesRemovesDuplicatePaths() {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let duplicate = makeEntry(name: "a.txt", path: "/tmp/a.txt")
        let unique = makeEntry(name: "b.txt", path: "/tmp/b.txt")

        let deduped = store.uniqueTransferEntries([duplicate, unique, duplicate])

        #expect(deduped.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    @Test
    func cancelledUploadStopsBeforeWritingRemoteData() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let service = RecordingRemoteFileService(directoryContents: [:])
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-cancelled-upload-\(UUID().uuidString).txt")
        try? Data("cancel me".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        var traversalBudget = RemoteFileTraversalBudget()
        var byteBudget = RemoteFileTransferByteBudget()
        var visitedIdentities: Set<LocalFileIdentity> = []
        let plan = try await store.makeLocalUploadPlan(
            at: localURL,
            depth: 0,
            traversalBudget: &traversalBudget,
            byteBudget: &byteBudget,
            visitedIdentities: &visitedIdentities
        )

        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            try await store.uploadLocalTransferPlan(
                plan,
                to: "/tmp",
                using: service,
                traversalBudget: &traversalBudget
            )
        }

        task.cancel()
        gate.continuation.yield()
        gate.continuation.finish()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(service.operations.isEmpty)
    }

    @Test
    func uploadReportsCurrentFileBeforeCompletingIt() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let service = RecordingRemoteFileService(directoryContents: [:])
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-progress-\(UUID().uuidString).txt")
        try Data("upload me".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        var progress: [RemoteFileBrowserStore.TransferProgress] = []
        let tracker = RemoteFileBrowserStore.TransferProgressTracker(
            totalUnitCount: 1,
            onProgress: { progress.append($0) }
        )
        var traversalBudget = RemoteFileTraversalBudget()
        var byteBudget = RemoteFileTransferByteBudget()
        var visitedIdentities: Set<LocalFileIdentity> = []
        let plan = try await store.makeLocalUploadPlan(
            at: localURL,
            depth: 0,
            traversalBudget: &traversalBudget,
            byteBudget: &byteBudget,
            visitedIdentities: &visitedIdentities
        )

        try await store.uploadLocalTransferPlan(
            plan,
            to: "/tmp",
            using: service,
            progressTracker: tracker,
            traversalBudget: &traversalBudget
        )

        #expect(progress.map(\.completedUnitCount) == [0, 1])
        #expect(progress.map(\.currentItemName) == [localURL.lastPathComponent, localURL.lastPathComponent])
    }

    @Test
    func localUploadPlanRejectsSymbolicLinks() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-link-\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: directory) }

        var traversalBudget = RemoteFileTraversalBudget()
        var byteBudget = RemoteFileTransferByteBudget()
        var visitedIdentities: Set<LocalFileIdentity> = []

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeLocalUploadPlan(
                at: link,
                depth: 0,
                traversalBudget: &traversalBudget,
                byteBudget: &byteBudget,
                visitedIdentities: &visitedIdentities
            )
        }
    }

    @Test
    func localUploadPlanRejectsFilesAboveThePerFileLimit() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-limit-\(UUID().uuidString).txt")
        try Data(repeating: 0x41, count: 5).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let limits = RemoteFileTransferLimits(
            maxDepth: 1,
            maxEntries: 2,
            maxEntriesPerDirectory: 2,
            maxFileBytes: 4,
            maxAggregateBytes: 8,
            maxElapsed: .seconds(10),
            minimumFreeBytes: 2
        )
        var traversalBudget = RemoteFileTraversalBudget(limits: limits)
        var byteBudget = RemoteFileTransferByteBudget(limits: limits)
        var visitedIdentities: Set<LocalFileIdentity> = []

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeLocalUploadPlan(
                at: localURL,
                depth: 0,
                traversalBudget: &traversalBudget,
                byteBudget: &byteBudget,
                visitedIdentities: &visitedIdentities
            )
        }
    }

    @Test
    func localUploadPlanBoundsDirectoryEnumeration() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("a.txt"))
        try Data().write(to: directory.appendingPathComponent("b.txt"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let limits = RemoteFileTransferLimits(
            maxDepth: 2,
            maxEntries: 10,
            maxEntriesPerDirectory: 1,
            maxFileBytes: 10,
            maxAggregateBytes: 10,
            maxElapsed: .seconds(10),
            minimumFreeBytes: 2
        )
        var traversalBudget = RemoteFileTraversalBudget(limits: limits)
        var byteBudget = RemoteFileTransferByteBudget(limits: limits)
        var visitedIdentities: Set<LocalFileIdentity> = []

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeLocalUploadPlan(
                at: directory,
                depth: 0,
                traversalBudget: &traversalBudget,
                byteBudget: &byteBudget,
                visitedIdentities: &visitedIdentities
            )
        }
    }

    @Test
    func localUploadPlanRejectsRepeatedFileIdentities() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-hardlink-\(UUID().uuidString)", isDirectory: true)
        let original = directory.appendingPathComponent("original.txt")
        let hardLink = directory.appendingPathComponent("linked.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("same file".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)
        defer { try? FileManager.default.removeItem(at: directory) }

        var traversalBudget = RemoteFileTraversalBudget()
        var byteBudget = RemoteFileTransferByteBudget()
        var visitedIdentities: Set<LocalFileIdentity> = []

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeLocalUploadPlan(
                at: directory,
                depth: 0,
                traversalBudget: &traversalBudget,
                byteBudget: &byteBudget,
                visitedIdentities: &visitedIdentities
            )
        }
    }

    @Test
    func uploadCapacityKeepsTheRemoteFreeSpaceReserve() throws {
        var budget = RemoteFileTransferByteBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 2,
                maxEntriesPerDirectory: 2,
                maxFileBytes: 100,
                maxAggregateBytes: 100,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 20
            )
        )
        try budget.record(11)

        #expect(throws: RemoteFileBrowserError.self) {
            try budget.validateUploadCapacity(availableBytes: 30)
        }
    }

    private func makeEntry(name: String, path: String, type: RemoteFileType = .file) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileTransferCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class RecordingRemoteFileService: RemoteFileService {
    enum Operation: Equatable {
        case deleteFile(String)
        case deleteDirectory(String)
        case upload(String)
    }

    let directoryContents: [String: [RemoteFileEntry]]
    let statEntries: [String: RemoteFileEntry]
    let downloadData: Data
    private(set) var operations: [Operation] = []
    private(set) var listedPaths: [String] = []

    init(
        directoryContents: [String: [RemoteFileEntry]],
        statEntries: [String: RemoteFileEntry] = [:],
        downloadData: Data = Data()
    ) {
        self.directoryContents = directoryContents
        self.statEntries = statEntries
        self.downloadData = downloadData
    }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] {
        let normalizedPath = RemoteFilePath.normalize(path)
        listedPaths.append(normalizedPath)
        return directoryContents[normalizedPath] ?? []
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        guard let entry = statEntries[RemoteFilePath.normalize(path)] else {
            throw RemoteFileBrowserError.pathNotFound
        }
        return entry
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        Data()
    }

    func downloadFile(at path: String, to localURL: URL, maxBytes: UInt64) async throws {
        guard UInt64(downloadData.count) <= maxBytes else {
            try? FileManager.default.removeItem(at: localURL)
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        try downloadData.write(to: localURL)
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {
        operations.append(.upload(RemoteFilePath.normalize(remotePath)))
    }

    func upload(
        fileAt localURL: URL,
        to remotePath: String,
        expectedBytes: UInt64,
        permissions: Int32
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard byteCount == expectedBytes else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        operations.append(.upload(RemoteFilePath.normalize(remotePath)))
    }

    func createDirectory(at path: String, permissions: Int32) async throws {}

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {}

    func deleteFile(at path: String) async throws {
        operations.append(.deleteFile(RemoteFilePath.normalize(path)))
    }

    func deleteDirectory(at path: String) async throws {
        operations.append(.deleteDirectory(RemoteFilePath.normalize(path)))
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {}

    func resolveHomeDirectory() async throws -> String {
        "/"
    }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }
}
