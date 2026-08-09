import Combine
import Foundation

extension RemoteFileBrowserStore {
    struct LocalUploadItemInfo: Sendable {
        let name: String
        let isDirectory: Bool
    }

    final class TransferProgressTracker {
        private(set) var completedUnitCount = 0
        let totalUnitCount: Int
        let onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?

        init(
            totalUnitCount: Int,
            onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?
        ) {
            self.totalUnitCount = max(1, totalUnitCount)
            self.onProgress = onProgress
        }

        @MainActor
        func reportCurrentItem(_ currentItemName: String) {
            onProgress?(
                TransferProgress(
                    completedUnitCount: min(completedUnitCount, totalUnitCount),
                    totalUnitCount: totalUnitCount,
                    currentItemName: currentItemName
                )
            )
        }

        @MainActor
        func advance(currentItemName: String) {
            completedUnitCount += 1
            onProgress?(
                TransferProgress(
                    completedUnitCount: min(completedUnitCount, totalUnitCount),
                    totalUnitCount: totalUnitCount,
                    currentItemName: currentItemName
                )
            )
        }
    }

    func upload(
        data: Data,
        to remotePath: String,
        server: Server,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            try await service.upload(
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
        server: Server,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        let leaf = try RemoteFileLeaf(validating: localURL.lastPathComponent)
        let remotePath = RemoteFilePath.appending(leaf, to: remoteDirectoryPath)
        let data = try await loadLocalFileData(from: localURL)
        try await upload(
            data: data,
            to: remotePath,
            server: server,
            permissions: permissions,
            strategy: strategy
        )
    }

    func createDirectory(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server,
        permissions: Int32 = 0o755
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.createDirectory(at: remotePath, permissions: permissions)
        }
    }

    func createDirectory(
        named directoryName: String,
        in remoteDirectoryPath: String,
        tab: RemoteFileTab,
        server: Server,
        permissions: Int32 = 0o755
    ) async throws {
        let leaf = try RemoteFileLeaf(validating: validatedRemoteName(directoryName))
        let remotePath = RemoteFilePath.appending(leaf, to: remoteDirectoryPath)
        try await createDirectory(at: remotePath, in: tab, server: server, permissions: permissions)
    }

    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.renameItem(at: sourcePath, to: destinationPath)
        }
    }

    func deleteFile(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.deleteFile(at: remotePath)
        }
    }

    func deleteDirectory(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { [self] service in
            try await deleteDirectoryRecursively(at: remotePath, using: service)
        }
    }

    func deleteItem(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server,
        type: RemoteFileType? = nil
    ) async throws {
        switch type {
        case .directory:
            try await deleteDirectory(at: remotePath, in: tab, server: server)
        case .file, .symlink, .other, nil:
            try await deleteFile(at: remotePath, in: tab, server: server)
        }
    }

    func setPermissions(
        _ entry: RemoteFileEntry,
        permissions: UInt32,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let updatedEntry = try await withRemoteFileService(for: server) { service in
            try await service.setPermissions(at: entry.path, permissions: permissions)
            return try await service.lstat(at: entry.path)
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

        updateState(for: tab) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path,
               let payload = state.viewerPayload,
               payload.entry.path == entry.path {
                state.viewerPhase = .loaded(RemoteFileViewerPayload(
                    previewKind: payload.previewKind,
                    entry: updatedEntry,
                    textPreview: payload.textPreview,
                    previewFileURL: payload.previewFileURL,
                    isTruncated: payload.isTruncated,
                    unavailableMessage: payload.unavailableMessage,
                    requiresExplicitDownload: payload.requiresExplicitDownload,
                    previewByteCount: payload.previewByteCount
                ))
            }
        }
    }

    func uploadFiles(
        at urls: [URL],
        to directoryPath: String,
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        let plans = urls.map { LocalUploadPlanItem(sourceURL: $0, remoteName: $0.lastPathComponent) }
        try await uploadFiles(
            plans: plans,
            to: directoryPath,
            in: tab,
            server: server,
            onProgress: onProgress
        )
    }

    func uploadFiles(
        plans: [LocalUploadPlanItem],
        to directoryPath: String,
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        let urls = plans.map(\.sourceURL)
        try await withSecurityScopedAccess(to: urls) {
            try Task.checkCancellation()
            let progressTracker = TransferProgressTracker(
                totalUnitCount: try await countLocalTransferUnits(at: urls),
                onProgress: onProgress
            )
            try await withRemoteFileService(for: server) { [self] service in
                for plan in plans {
                    try Task.checkCancellation()
                    try await self.uploadItem(
                        at: plan.sourceURL,
                        to: destinationDirectory,
                        remoteName: plan.remoteName,
                        using: service,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(for: tab)
        await refresh(server: server, tab: tab)
    }

    func uploadFilesResolvingConflicts(
        at urls: [URL],
        to directoryPath: String,
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        try await withSecurityScopedAccess(to: urls) {
            try Task.checkCancellation()
            let progressTracker = TransferProgressTracker(
                totalUnitCount: try await countLocalTransferUnits(at: urls),
                onProgress: onProgress
            )

            try await withRemoteFileService(for: server) { [self] service in
                let candidates = try await localUploadPlanCandidates(
                    at: urls,
                    in: destinationDirectory,
                    using: service
                )

                for candidate in candidates {
                    try Task.checkCancellation()
                    try await uploadItem(
                        at: candidate.sourceURL,
                        to: destinationDirectory,
                        remoteName: candidate.suggestedName ?? candidate.originalName,
                        using: service,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(for: tab)
        await refresh(server: server, tab: tab)
    }

    func prepareLocalUploadPlan(
        at urls: [URL],
        to directoryPath: String,
        server: Server
    ) async throws -> [LocalUploadPlanCandidate] {
        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        return try await withSecurityScopedAccess(to: urls) {
            try await withRemoteFileService(for: server) { service in
                try await self.localUploadPlanCandidates(
                    at: urls,
                    in: destinationDirectory,
                    using: service
                )
            }
        }
    }

    func localUploadPlanCandidates(
        at urls: [URL],
        in destinationDirectory: String,
        using service: any RemoteFileService
    ) async throws -> [LocalUploadPlanCandidate] {
        var reservedNames: Set<String> = []
        var candidates: [LocalUploadPlanCandidate] = []

        for url in urls {
            try Task.checkCancellation()
            let itemInfo = try await localItemInfo(at: url)
            let originalName = itemInfo.name
            let resolution = try await conflictResolver.resolveName(
                for: originalName,
                in: destinationDirectory,
                policy: .keepBoth,
                using: service,
                reservedNames: &reservedNames
            )
            candidates.append(
                LocalUploadPlanCandidate(
                    sourceURL: url,
                    originalName: originalName,
                    existingEntry: resolution.existingEntry,
                    suggestedName: resolution.hasConflict ? resolution.resolvedName : nil
                )
            )
        }

        return candidates
    }

    func copyEntries(
        _ entries: [RemoteFileEntry],
        from sourceServerId: UUID,
        to destinationDirectoryPath: String,
        destinationTab: RemoteFileTab,
        destinationServer: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard destinationTab.serverId == destinationServer.id,
              let sourceServer = server(for: sourceServerId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let uniqueEntries = uniqueTransferEntries(entries)
        guard !uniqueEntries.isEmpty else { return }

        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        let plans = try await withRemoteFileService(for: sourceServer) { service in
            var traversalBudget = RemoteFileTraversalBudget()
            var plans: [RemoteFileTransferPlanNode] = []
            for entry in uniqueEntries {
                plans.append(try await self.makeRemoteTransferPlan(
                    for: entry,
                    using: service,
                    symlinkPolicy: .resolveFiles,
                    depth: 0,
                    budget: &traversalBudget
                ))
            }
            return plans
        }
        let progressTracker = TransferProgressTracker(
            totalUnitCount: plans.reduce(0) { $0 + $1.unitCount },
            onProgress: onProgress
        )

        try await withRemoteFileService(for: sourceServer) { sourceService in
            try await self.withRemoteFileService(for: destinationServer) { destinationService in
                var byteBudget = RemoteFileTransferByteBudget()
                for plan in plans {
                    try await self.copyRemoteTransferPlan(
                        plan,
                        to: destinationDirectory,
                        operationRootPath: destinationDirectory,
                        sourceService: sourceService,
                        destinationService: destinationService,
                        progressTracker: progressTracker,
                        byteBudget: &byteBudget
                    )
                }
            }
        }

        clearViewer(for: destinationTab)
        await refresh(server: destinationServer, tab: destinationTab)
    }

    func downloadFile(
        at remotePath: String,
        to localURL: URL,
        server: Server
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            let entry = try await service.stat(at: remotePath)
            guard entry.type != .directory else {
                throw RemoteFileBrowserError.resourceLimitExceeded
            }
            var byteBudget = RemoteFileTransferByteBudget()
            let limit = try self.downloadLimit(
                reportedBytes: entry.size,
                to: localURL,
                byteBudget: byteBudget
            )
            try await service.downloadFile(at: remotePath, to: localURL, maxBytes: limit)
            try byteBudget.record(try self.downloadedFileSize(at: localURL))
        }
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        server: Server
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            var traversalBudget = RemoteFileTraversalBudget()
            let plan = try await self.makeRemoteTransferPlan(
                for: entry,
                using: service,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &traversalBudget
            )
            var byteBudget = RemoteFileTransferByteBudget()
            try await self.downloadRemoteTransferPlan(
                plan,
                to: localURL,
                operationRootURL: localURL,
                using: service,
                byteBudget: &byteBudget
            )
        }
    }

    func listDirectories(
        at path: String,
        server: Server
    ) async throws -> [RemoteFileEntry] {
        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withRemoteFileService(for: server) { service in
            try await service.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        return entries
            .filter { $0.type == .directory }
            .sortedForBrowser(using: .name, direction: .ascending)
    }

    func performMutation(
        in tab: RemoteFileTab,
        server: Server,
        operation: @escaping (any RemoteFileService) async throws -> Void
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withRemoteFileService(for: server) { service in
            try await operation(service)
        }
        await refresh(server: server, tab: tab)
    }

    func deleteDirectoryRecursively(
        at remotePath: String,
        using service: any RemoteFileService
    ) async throws {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        guard normalizedPath != "/",
              let rootName = normalizedPath.split(separator: "/").last.map(String.init) else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        let root = RemoteFileEntry(
            name: rootName,
            path: normalizedPath,
            type: .directory,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
        var budget = RemoteFileTraversalBudget()
        let plan = try await makeRemoteTransferPlan(
            for: root,
            using: service,
            symlinkPolicy: .preserve,
            depth: 0,
            budget: &budget
        )
        try await deleteRemoteTransferPlan(plan, using: service)
    }

    func loadLocalFileData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
    }

    func localItemInfo(at url: URL) async throws -> LocalUploadItemInfo {
        try await Task.detached(priority: .utility) {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            return LocalUploadItemInfo(
                name: resourceValues.name ?? url.lastPathComponent,
                isDirectory: resourceValues.isDirectory == true
            )
        }.value
    }

    func localDirectoryContents(at url: URL) async throws -> [URL] {
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

    func uploadItem(
        at localURL: URL,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        using client: any RemoteFileService,
        progressTracker: TransferProgressTracker? = nil
    ) async throws {
        try Task.checkCancellation()
        let itemInfo = try await localItemInfo(at: localURL)
        let targetName = remoteName ?? itemInfo.name
        let targetLeaf = try RemoteFileLeaf(validating: targetName)
        let remotePath = RemoteFilePath.appending(targetLeaf, to: remoteDirectoryPath)
        progressTracker?.reportCurrentItem(targetName)

        if itemInfo.isDirectory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: 0o755,
                using: client
            )
            progressTracker?.advance(currentItemName: targetName)
            let children = try await localDirectoryContents(at: localURL)
            for child in children {
                try Task.checkCancellation()
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
        try Task.checkCancellation()
        try await client.upload(data, to: remotePath, permissions: Int32(0o644), strategy: .automatic)
        try Task.checkCancellation()
        progressTracker?.advance(currentItemName: targetName)
    }

    enum TransferSymlinkPolicy: Equatable {
        case preserve
        case resolveFiles
    }

    func makeRemoteTransferPlan(
        for entry: RemoteFileEntry,
        using service: any RemoteFileService,
        symlinkPolicy: TransferSymlinkPolicy,
        depth: Int,
        budget: inout RemoteFileTraversalBudget
    ) async throws -> RemoteFileTransferPlanNode {
        try Task.checkCancellation()
        try budget.admit(depth: depth)
        let safeEntry = try validatedTransferEntry(entry)
        let effectiveEntry: RemoteFileEntry

        if safeEntry.type == .symlink, symlinkPolicy == .resolveFiles {
            let resolved = try await service.stat(at: safeEntry.path)
            guard resolved.type != .directory else {
                throw RemoteFileBrowserError.resourceLimitExceeded
            }
            effectiveEntry = RemoteFileEntry(
                name: safeEntry.name,
                path: safeEntry.path,
                type: resolved.type,
                size: resolved.size,
                modifiedAt: resolved.modifiedAt,
                permissions: resolved.permissions,
                symlinkTarget: safeEntry.symlinkTarget ?? resolved.symlinkTarget
            )
        } else {
            effectiveEntry = safeEntry
        }

        guard effectiveEntry.type == .directory else {
            return RemoteFileTransferPlanNode(entry: effectiveEntry, children: [])
        }

        let allowedChildren = try budget.directoryReadLimit()
        let listedChildren = try await service.listDirectory(
            at: effectiveEntry.path,
            maxEntries: allowedChildren + 1
        )
        guard listedChildren.count <= allowedChildren else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }

        var children: [RemoteFileTransferPlanNode] = []
        children.reserveCapacity(listedChildren.count)
        for child in listedChildren {
            let safeChild = try validatedTransferEntry(child, parentPath: effectiveEntry.path)
            children.append(try await makeRemoteTransferPlan(
                for: safeChild,
                using: service,
                symlinkPolicy: symlinkPolicy,
                depth: depth + 1,
                budget: &budget
            ))
        }
        return RemoteFileTransferPlanNode(entry: effectiveEntry, children: children)
    }

    func downloadRemoteTransferPlan(
        _ plan: RemoteFileTransferPlanNode,
        to localURL: URL,
        operationRootURL: URL,
        using service: any RemoteFileService,
        byteBudget: inout RemoteFileTransferByteBudget
    ) async throws {
        try Task.checkCancellation()
        if plan.entry.type == .directory {
            try await createLocalDirectory(at: localURL)
            for child in plan.children {
                let leaf = try RemoteFileLeaf(validating: child.entry.name)
                let childURL = try RemoteFileLocalPath.descendant(
                    named: leaf,
                    in: localURL,
                    operationRootURL: operationRootURL,
                    isDirectory: child.entry.type == .directory
                )
                try await downloadRemoteTransferPlan(
                    child,
                    to: childURL,
                    operationRootURL: operationRootURL,
                    using: service,
                    byteBudget: &byteBudget
                )
            }
            return
        }

        let limit = try downloadLimit(
            reportedBytes: plan.entry.size,
            to: localURL,
            byteBudget: byteBudget
        )
        try await service.downloadFile(at: plan.entry.path, to: localURL, maxBytes: limit)
        try byteBudget.record(try downloadedFileSize(at: localURL))
    }

    func copyRemoteTransferPlan(
        _ plan: RemoteFileTransferPlanNode,
        to remoteDirectoryPath: String,
        operationRootPath: String,
        sourceService: any RemoteFileService,
        destinationService: any RemoteFileService,
        progressTracker: TransferProgressTracker?,
        byteBudget: inout RemoteFileTransferByteBudget
    ) async throws {
        try Task.checkCancellation()
        let leaf = try RemoteFileLeaf(validating: plan.entry.name)
        let remotePath = RemoteFilePath.appending(leaf, to: remoteDirectoryPath)
        guard RemoteFilePath.isStrictDescendant(remotePath, of: operationRootPath) else {
            throw RemoteFileBrowserError.destinationEscapedRoot
        }

        if plan.entry.type == .directory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: Int32(plan.entry.permissions ?? 0o755),
                using: destinationService
            )
            progressTracker?.advance(currentItemName: plan.entry.name)
            for child in plan.children {
                try await copyRemoteTransferPlan(
                    child,
                    to: remotePath,
                    operationRootPath: operationRootPath,
                    sourceService: sourceService,
                    destinationService: destinationService,
                    progressTracker: progressTracker,
                    byteBudget: &byteBudget
                )
            }
            return
        }

        let temporaryURL = try temporaryStorage.makeTransferFileURL(for: plan.entry)
        defer { temporaryStorage.removeItem(at: temporaryURL) }
        let limit = try downloadLimit(
            reportedBytes: plan.entry.size,
            to: temporaryURL,
            byteBudget: byteBudget
        )
        try await sourceService.downloadFile(at: plan.entry.path, to: temporaryURL, maxBytes: limit)
        let downloadedBytes = try downloadedFileSize(at: temporaryURL)
        try byteBudget.record(downloadedBytes)
        let data = try await loadLocalFileData(from: temporaryURL)
        try await destinationService.upload(
            data,
            to: remotePath,
            permissions: Int32(plan.entry.permissions ?? 0o644),
            strategy: .automatic
        )
        progressTracker?.advance(currentItemName: plan.entry.name)
    }

    func deleteRemoteTransferPlan(
        _ plan: RemoteFileTransferPlanNode,
        using service: any RemoteFileService
    ) async throws {
        for child in plan.children {
            try await deleteRemoteTransferPlan(child, using: service)
        }
        if plan.entry.type == .directory {
            try await service.deleteDirectory(at: plan.entry.path)
        } else {
            try await service.deleteFile(at: plan.entry.path)
        }
    }

    func countLocalTransferUnits(at urls: [URL]) async throws -> Int {
        var totalUnitCount = 0

        for url in urls {
            totalUnitCount += try await countLocalTransferUnits(at: url)
        }

        return max(1, totalUnitCount)
    }

    func countLocalTransferUnits(at url: URL) async throws -> Int {
        let itemInfo = try await localItemInfo(at: url)
        guard itemInfo.isDirectory else { return 1 }

        let children = try await localDirectoryContents(at: url)
        var totalUnitCount = 1

        for child in children {
            totalUnitCount += try await countLocalTransferUnits(at: child)
        }

        return totalUnitCount
    }

    func countRemoteTransferUnits(
        for entries: [RemoteFileEntry],
        using client: any RemoteFileService
    ) async throws -> Int {
        var budget = RemoteFileTraversalBudget()
        var totalUnitCount = 0
        for entry in entries {
            let plan = try await makeRemoteTransferPlan(
                for: entry,
                using: client,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &budget
            )
            totalUnitCount += plan.unitCount
        }
        return max(1, totalUnitCount)
    }

    func countRemoteTransferUnits(
        for entry: RemoteFileEntry,
        using client: any RemoteFileService
    ) async throws -> Int {
        try await countRemoteTransferUnits(for: [entry], using: client)
    }

    func validatedTransferEntry(
        _ entry: RemoteFileEntry,
        parentPath: String? = nil
    ) throws -> RemoteFileEntry {
        let leaf = try RemoteFileLeaf(validating: entry.name)
        let normalizedPath = RemoteFilePath.normalize(entry.path)
        let expectedPath = RemoteFilePath.appending(
            leaf,
            to: parentPath ?? RemoteFilePath.parent(of: normalizedPath)
        )
        guard normalizedPath == expectedPath else {
            throw RemoteFileBrowserError.invalidEntryName
        }
        return RemoteFileEntry(
            name: leaf.value,
            path: normalizedPath,
            type: entry.type,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            permissions: entry.permissions,
            symlinkTarget: entry.symlinkTarget
        )
    }

    func downloadedFileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func downloadLimit(
        reportedBytes: UInt64?,
        to localURL: URL,
        byteBudget: RemoteFileTransferByteBudget
    ) throws -> UInt64 {
        try byteBudget.downloadLimit(
            reportedBytes: reportedBytes,
            availableCapacity: availableDownloadCapacity(at: localURL)
        )
    }

    func availableDownloadCapacity(at localURL: URL) throws -> UInt64 {
        let directoryURL = localURL.deletingLastPathComponent()
        let values = try directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let capacity = values.volumeAvailableCapacityForImportantUsage,
           let exactCapacity = UInt64(exactly: capacity) {
            return exactCapacity
        }

        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: directoryURL.path
        )
        guard let capacity = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        return capacity
    }

    func ensureRemoteDirectoryExists(
        at remotePath: String,
        permissions: Int32,
        using client: any RemoteFileService
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

    func uniqueTransferEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        var seenPaths: Set<String> = []
        return entries.filter { seenPaths.insert($0.path).inserted }
    }

    func createLocalDirectory(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    func withSecurityScopedAccess<T>(
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

    func validatedRemoteName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "A name is required."))
        }
        return try RemoteFileLeaf(validating: trimmed).value
    }
}
