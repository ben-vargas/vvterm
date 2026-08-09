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
                maxElapsed: .seconds(10)
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
    func cancelledUploadStopsBeforeWritingRemoteData() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let service = RecordingRemoteFileService(directoryContents: [:])
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-cancelled-upload-\(UUID().uuidString).txt")
        try? Data("cancel me".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            try await store.uploadItem(
                at: localURL,
                to: "/tmp",
                using: service
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

        try await store.uploadItem(
            at: localURL,
            to: "/tmp",
            using: service,
            progressTracker: tracker
        )

        #expect(progress.map(\.completedUnitCount) == [0, 1])
        #expect(progress.map(\.currentItemName) == [localURL.lastPathComponent, localURL.lastPathComponent])
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

    func downloadFile(at path: String, to localURL: URL) async throws {
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
