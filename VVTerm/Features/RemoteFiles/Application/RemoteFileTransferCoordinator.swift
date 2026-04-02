import Foundation

private struct LocalUploadItemInfo: Sendable {
    let name: String
    let isDirectory: Bool
}

private final class TransferProgressTracker {
    private(set) var completedUnitCount = 0
    let totalUnitCount: Int
    let onProgress: (@MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void)?

    init(
        totalUnitCount: Int,
        onProgress: (@MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void)?
    ) {
        self.totalUnitCount = max(1, totalUnitCount)
        self.onProgress = onProgress
    }

    @MainActor
    func advance(currentItemName: String) {
        completedUnitCount += 1
        onProgress?(
            RemoteFileBrowserStore.TransferProgress(
                completedUnitCount: min(completedUnitCount, totalUnitCount),
                totalUnitCount: totalUnitCount,
                currentItemName: currentItemName
            )
        )
    }
}

extension RemoteFileBrowserStore {
    struct TransferProgress: Sendable {
        let completedUnitCount: Int
        let totalUnitCount: Int
        let currentItemName: String
    }

    struct LocalUploadPlanItem: Identifiable, Sendable {
        let sourceURL: URL
        let remoteName: String

        var id: String {
            "\(sourceURL.absoluteString)->\(remoteName)"
        }
    }

    struct LocalUploadPlanCandidate: Identifiable, Sendable {
        let sourceURL: URL
        let originalName: String
        let existingEntry: RemoteFileEntry?
        let suggestedName: String?

        var id: String {
            "\(sourceURL.absoluteString)->\(originalName)"
        }

        var hasConflict: Bool {
            existingEntry != nil
        }
    }

    func upload(
        data: Data,
        to remotePath: String,
        serverId: UUID,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func upload(
        fileAt localURL: URL,
        to remoteDirectoryPath: String,
        serverId: UUID,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        let remotePath = RemoteFilePath.appending(localURL.lastPathComponent, to: remoteDirectoryPath)
        let data = try await loadLocalFileData(from: localURL)
        try await upload(
            data: data,
            to: remotePath,
            serverId: serverId,
            permissions: permissions,
            strategy: strategy
        )
    }

    func createDirectory(
        at remotePath: String,
        serverId: UUID,
        permissions: Int32 = 0o755
    ) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.createDirectory(at: remotePath, permissions: permissions)
        }
    }

    func createDirectory(
        named directoryName: String,
        in remoteDirectoryPath: String,
        serverId: UUID,
        permissions: Int32 = 0o755
    ) async throws {
        let remotePath = RemoteFilePath.appending(
            try validatedRemoteName(directoryName),
            to: remoteDirectoryPath
        )
        try await createDirectory(at: remotePath, serverId: serverId, permissions: permissions)
    }

    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        serverId: UUID
    ) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.renameItem(at: sourcePath, to: destinationPath)
        }
    }

    func deleteFile(at remotePath: String, serverId: UUID) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.deleteFile(at: remotePath)
        }
    }

    func deleteDirectory(at remotePath: String, serverId: UUID) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.deleteDirectory(at: remotePath)
        }
    }

    func deleteItem(
        at remotePath: String,
        serverId: UUID,
        type: RemoteFileType? = nil
    ) async throws {
        switch type {
        case .directory:
            try await deleteDirectory(at: remotePath, serverId: serverId)
        case .file, .symlink, .other, nil:
            try await deleteFile(at: remotePath, serverId: serverId)
        }
    }

    func setPermissions(_ entry: RemoteFileEntry, permissions: UInt32, serverId: UUID) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let updatedEntry = try await withClient(for: server) { client in
            try await client.setPermissions(at: entry.path, permissions: permissions)
            return try await client.lstat(at: entry.path)
        }

        let requestedPermissionBits = permissions & 0o7777
        let updatedPermissionBits = (updatedEntry.permissions ?? 0) & 0o7777
        if updatedPermissionBits != requestedPermissionBits {
            throw RemoteFileBrowserError.failed(
                String(
                    localized: "This server accepted the request, but the file permissions did not change. Some remote systems, including many Windows SFTP servers, do not support POSIX chmod."
                )
            )
        }

        updateState(for: serverId) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path,
               let payload = state.viewerPayload,
               payload.entry.path == entry.path {
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: payload.previewKind,
                    entry: updatedEntry,
                    textPreview: payload.textPreview,
                    previewFileURL: payload.previewFileURL,
                    isTruncated: payload.isTruncated,
                    unavailableMessage: payload.unavailableMessage,
                    requiresExplicitDownload: payload.requiresExplicitDownload,
                    previewByteCount: payload.previewByteCount
                )
            }
        }
    }

    func saveTextPreview(_ text: String, for entry: RemoteFileEntry, serverId: UUID) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        guard let data = text.data(using: .utf8) else {
            throw RemoteFileBrowserError.unsupportedEncoding
        }

        let updatedEntry = try await withClient(for: server) { client in
            let effectivePermissions = Int32(entry.permissions ?? 0o644)
            try await client.upload(data, to: entry.path, permissions: effectivePermissions)
            return try await client.lstat(at: entry.path)
        }

        updateState(for: serverId) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path {
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: .text,
                    entry: updatedEntry,
                    textPreview: text,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: nil,
                    requiresExplicitDownload: false,
                    previewByteCount: UInt64(data.count)
                )
                state.viewerError = nil
            }
        }
    }

    func uploadFiles(
        at urls: [URL],
        to directoryPath: String,
        serverId: UUID,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        let plans = urls.map { LocalUploadPlanItem(sourceURL: $0, remoteName: $0.lastPathComponent) }
        try await uploadFiles(
            plans: plans,
            to: directoryPath,
            serverId: serverId,
            onProgress: onProgress
        )
    }

    func uploadFiles(
        plans: [LocalUploadPlanItem],
        to directoryPath: String,
        serverId: UUID,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        let urls = plans.map(\.sourceURL)
        try await withSecurityScopedAccess(to: urls) {
            let progressTracker = TransferProgressTracker(
                totalUnitCount: try await countLocalTransferUnits(at: urls),
                onProgress: onProgress
            )
            try await withClient(for: server) { client in
                for plan in plans {
                    try await self.uploadItem(
                        at: plan.sourceURL,
                        to: destinationDirectory,
                        remoteName: plan.remoteName,
                        using: client,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(serverId: serverId)
        await refresh(serverId: serverId)
    }

    func prepareLocalUploadPlan(
        at urls: [URL],
        to directoryPath: String,
        serverId: UUID
    ) async throws -> [LocalUploadPlanCandidate] {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        return try await withSecurityScopedAccess(to: urls) {
            try await withClient(for: server) { client in
                var reservedNames: Set<String> = []
                var candidates: [LocalUploadPlanCandidate] = []

                for url in urls {
                    let itemInfo = try await self.localItemInfo(at: url)
                    let originalName = itemInfo.name
                    let remotePath = RemoteFilePath.appending(originalName, to: destinationDirectory)

                    do {
                        let existingEntry = try await client.lstat(at: remotePath)
                        let suggestedName = try await self.uniqueUploadName(
                            for: originalName,
                            in: destinationDirectory,
                            using: client,
                            reservedNames: &reservedNames
                        )
                        candidates.append(
                            LocalUploadPlanCandidate(
                                sourceURL: url,
                                originalName: originalName,
                                existingEntry: existingEntry,
                                suggestedName: suggestedName
                            )
                        )
                    } catch let error as RemoteFileBrowserError {
                        if error == .pathNotFound {
                            reservedNames.insert(originalName)
                            candidates.append(
                                LocalUploadPlanCandidate(
                                    sourceURL: url,
                                    originalName: originalName,
                                    existingEntry: nil,
                                    suggestedName: nil
                                )
                            )
                        } else {
                            throw error
                        }
                    }
                }

                return candidates
            }
        }
    }

    func copyEntries(
        _ entries: [RemoteFileEntry],
        from sourceServerId: UUID,
        to destinationDirectoryPath: String,
        destinationServerId: UUID,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard let sourceServer = server(for: sourceServerId),
              let destinationServer = server(for: destinationServerId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let uniqueEntries = uniqueTransferEntries(entries)
        guard !uniqueEntries.isEmpty else { return }

        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        let totalUnitCount = try await withClient(for: sourceServer) { client in
            try await self.countRemoteTransferUnits(for: uniqueEntries, using: client)
        }
        let progressTracker = TransferProgressTracker(
            totalUnitCount: totalUnitCount,
            onProgress: onProgress
        )

        try await withClient(for: sourceServer) { sourceClient in
            try await self.withClient(for: destinationServer) { destinationClient in
                for entry in uniqueEntries {
                    try await self.copyRemoteEntry(
                        entry,
                        to: destinationDirectory,
                        sourceClient: sourceClient,
                        destinationClient: destinationClient,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(serverId: destinationServerId)
        await refresh(serverId: destinationServerId)
    }

    func downloadFile(
        at remotePath: String,
        to localURL: URL,
        serverId: UUID
    ) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withClient(for: server) { client in
            try await client.downloadFile(at: remotePath, to: localURL)
        }
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        serverId: UUID
    ) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withClient(for: server) { client in
            try await self.downloadItem(entry, to: localURL, using: client)
        }
    }

    func listDirectories(at path: String, serverId: UUID) async throws -> [RemoteFileEntry] {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withClient(for: server) { client in
            try await client.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        return entries
            .filter { $0.type == .directory }
            .sortedForBrowser(using: .name, direction: .ascending)
    }

    private func performMutation(
        serverId: UUID,
        operation: @escaping (SSHClient) async throws -> Void
    ) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withClient(for: server) { client in
            try await operation(client)
        }
        await refresh(serverId: serverId)
    }

    private func loadLocalFileData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
    }

    private func localItemInfo(at url: URL) async throws -> LocalUploadItemInfo {
        try await Task.detached(priority: .utility) {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            return LocalUploadItemInfo(
                name: resourceValues.name ?? url.lastPathComponent,
                isDirectory: resourceValues.isDirectory == true
            )
        }.value
    }

    private func localDirectoryContents(at url: URL) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                options: []
            )
            return contents.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }.value
    }

    private func uploadItem(
        at localURL: URL,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        using client: SSHClient,
        progressTracker: TransferProgressTracker? = nil
    ) async throws {
        let itemInfo = try await localItemInfo(at: localURL)
        let targetName = remoteName ?? itemInfo.name
        let remotePath = RemoteFilePath.appending(targetName, to: remoteDirectoryPath)

        if itemInfo.isDirectory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: 0o755,
                using: client
            )
            progressTracker?.advance(currentItemName: targetName)
            let children = try await localDirectoryContents(at: localURL)
            for child in children {
                try await uploadItem(
                    at: child,
                    to: remotePath,
                    using: client,
                    progressTracker: progressTracker
                )
            }
            return
        }

        let data = try await loadLocalFileData(from: localURL)
        try await client.upload(data, to: remotePath, permissions: 0o644)
        progressTracker?.advance(currentItemName: targetName)
    }

    private func uniqueUploadName(
        for originalName: String,
        in remoteDirectoryPath: String,
        using client: SSHClient,
        reservedNames: inout Set<String>
    ) async throws -> String {
        let fileURL = URL(fileURLWithPath: originalName)
        let pathExtension = fileURL.pathExtension
        let baseName = pathExtension.isEmpty
            ? originalName
            : fileURL.deletingPathExtension().lastPathComponent

        for index in 2...10_000 {
            let candidateName: String
            if pathExtension.isEmpty {
                candidateName = "\(baseName) \(index)"
            } else {
                candidateName = "\(baseName) \(index).\(pathExtension)"
            }

            guard !reservedNames.contains(candidateName) else { continue }

            let candidatePath = RemoteFilePath.appending(candidateName, to: remoteDirectoryPath)
            do {
                _ = try await client.lstat(at: candidatePath)
                continue
            } catch let error as RemoteFileBrowserError {
                if error == .pathNotFound {
                    reservedNames.insert(candidateName)
                    return candidateName
                }
                throw error
            }
        }

        throw RemoteFileBrowserError.failed(
            String(localized: "Unable to generate a unique name for the uploaded item.")
        )
    }

    private func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        using client: SSHClient
    ) async throws {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: client)

        if effectiveEntry.type == .directory {
            try await createLocalDirectory(at: localURL)
            let children = try await client.listDirectory(at: entry.path)
            for child in children {
                let childURL = localURL.appendingPathComponent(
                    child.name,
                    isDirectory: child.type == .directory
                )
                try await downloadItem(child, to: childURL, using: client)
            }
            return
        }

        try await client.downloadFile(at: entry.path, to: localURL)
    }

    private func copyRemoteEntry(
        _ entry: RemoteFileEntry,
        to remoteDirectoryPath: String,
        sourceClient: SSHClient,
        destinationClient: SSHClient,
        progressTracker: TransferProgressTracker?
    ) async throws {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: sourceClient)
        let remotePath = RemoteFilePath.appending(entry.name, to: remoteDirectoryPath)

        if effectiveEntry.type == .directory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: Int32(effectiveEntry.permissions ?? 0o755),
                using: destinationClient
            )
            progressTracker?.advance(currentItemName: entry.name)
            let children = try await sourceClient.listDirectory(at: entry.path)
            for child in children {
                try await copyRemoteEntry(
                    child,
                    to: remotePath,
                    sourceClient: sourceClient,
                    destinationClient: destinationClient,
                    progressTracker: progressTracker
                )
            }
            return
        }

        let temporaryURL = try temporaryTransferURL(for: entry)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try await sourceClient.downloadFile(at: entry.path, to: temporaryURL)
        let data = try await loadLocalFileData(from: temporaryURL)
        try await destinationClient.upload(
            data,
            to: remotePath,
            permissions: Int32(effectiveEntry.permissions ?? 0o644)
        )
        progressTracker?.advance(currentItemName: entry.name)
    }

    private func countLocalTransferUnits(at urls: [URL]) async throws -> Int {
        var totalUnitCount = 0

        for url in urls {
            totalUnitCount += try await countLocalTransferUnits(at: url)
        }

        return max(1, totalUnitCount)
    }

    private func countLocalTransferUnits(at url: URL) async throws -> Int {
        let itemInfo = try await localItemInfo(at: url)
        guard itemInfo.isDirectory else { return 1 }

        let children = try await localDirectoryContents(at: url)
        var totalUnitCount = 1

        for child in children {
            totalUnitCount += try await countLocalTransferUnits(at: child)
        }

        return totalUnitCount
    }

    private func countRemoteTransferUnits(
        for entries: [RemoteFileEntry],
        using client: SSHClient
    ) async throws -> Int {
        var totalUnitCount = 0

        for entry in entries {
            totalUnitCount += try await countRemoteTransferUnits(for: entry, using: client)
        }

        return max(1, totalUnitCount)
    }

    private func countRemoteTransferUnits(
        for entry: RemoteFileEntry,
        using client: SSHClient
    ) async throws -> Int {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: client)
        guard effectiveEntry.type == .directory else { return 1 }

        let children = try await client.listDirectory(at: entry.path)
        var totalUnitCount = 1

        for child in children {
            totalUnitCount += try await countRemoteTransferUnits(for: child, using: client)
        }

        return totalUnitCount
    }

    private func resolvedTransferEntry(
        for entry: RemoteFileEntry,
        using client: SSHClient
    ) async throws -> RemoteFileEntry {
        guard entry.type == .symlink else { return entry }

        let resolvedEntry = try await client.stat(at: entry.path)
        return RemoteFileEntry(
            name: entry.name,
            path: entry.path,
            type: resolvedEntry.type,
            size: resolvedEntry.size,
            modifiedAt: resolvedEntry.modifiedAt,
            permissions: resolvedEntry.permissions,
            symlinkTarget: entry.symlinkTarget ?? resolvedEntry.symlinkTarget
        )
    }

    private func ensureRemoteDirectoryExists(
        at remotePath: String,
        permissions: Int32,
        using client: SSHClient
    ) async throws {
        do {
            let existingEntry = try await client.lstat(at: remotePath)
            guard existingEntry.type == .directory else {
                throw RemoteFileBrowserError.failed(
                    String(
                        format: String(localized: "\"%@\" already exists and is not a folder."),
                        existingEntry.name.isEmpty ? remotePath : existingEntry.name
                    )
                )
            }
        } catch let error as RemoteFileBrowserError {
            guard case .pathNotFound = error else { throw error }
            try await client.createDirectory(at: remotePath, permissions: permissions)
        } catch {
            throw error
        }
    }

    private func temporaryTransferURL(for entry: RemoteFileEntry) throws -> URL {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VVTermTransferStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let itemName = entry.name.isEmpty ? "download" : entry.name
        return rootDirectory.appendingPathComponent(UUID().uuidString + "-" + itemName)
    }

    private func uniqueTransferEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        var seenPaths: Set<String> = []
        return entries.filter { seenPaths.insert($0.path).inserted }
    }

    private func createLocalDirectory(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    private func withSecurityScopedAccess<T>(
        to urls: [URL],
        operation: () async throws -> T
    ) async throws -> T {
        let accessedURLs = urls.map { url in
            (url: url, accessed: url.startAccessingSecurityScopedResource())
        }
        defer {
            for entry in accessedURLs where entry.accessed {
                entry.url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }

    private func validatedRemoteName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "A name is required."))
        }
        guard trimmed != "." && trimmed != ".." else {
            throw RemoteFileBrowserError.failed(String(localized: "This name is not allowed."))
        }
        guard !trimmed.contains("/") else {
            throw RemoteFileBrowserError.failed(String(localized: "Names cannot contain '/'."))
        }
        return trimmed
    }
}
