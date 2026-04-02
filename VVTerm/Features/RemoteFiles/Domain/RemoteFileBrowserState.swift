import Foundation

struct RemoteFileFilesystemStatus: Hashable, Sendable {
    let blockSize: UInt64
    let totalBlocks: UInt64
    let freeBlocks: UInt64
    let availableBlocks: UInt64

    var totalBytes: UInt64 {
        blockSize.saturatingMultiply(totalBlocks)
    }

    var freeBytes: UInt64 {
        blockSize.saturatingMultiply(freeBlocks)
    }

    var availableBytes: UInt64 {
        blockSize.saturatingMultiply(availableBlocks)
    }
}

struct RemoteFileBrowserState: Sendable {
    var currentPath: String?
    var entries: [RemoteFileEntry]
    var sort: RemoteFileSort
    var sortDirection: RemoteFileSortDirection
    var showHiddenFiles: Bool
    var hasCustomizedHiddenFiles: Bool
    var isLoadingDirectory: Bool
    var isLoadingViewer: Bool
    var isDirectoryTruncated: Bool
    var filesystemStatus: RemoteFileFilesystemStatus?
    var error: RemoteFileBrowserError?
    var viewerError: RemoteFileBrowserError?
    var viewerPayload: RemoteFileViewerPayload?
    var selectedEntryPath: String?

    init(persisted: RemoteFileBrowserPersistedState = .init()) {
        currentPath = persisted.lastVisitedPath.map { RemoteFilePath.normalize($0) }
        entries = []
        sort = persisted.sort
        sortDirection = persisted.sortDirection
        showHiddenFiles = persisted.showHiddenFiles
        hasCustomizedHiddenFiles = persisted.hasCustomizedHiddenFiles
        isLoadingDirectory = false
        isLoadingViewer = false
        isDirectoryTruncated = false
        filesystemStatus = nil
        error = nil
        viewerError = nil
        viewerPayload = nil
        selectedEntryPath = nil
    }

    var breadcrumbs: [RemoteFileBreadcrumb] {
        guard let currentPath else { return [] }
        return RemoteFilePath.breadcrumbs(for: currentPath)
    }
}

private extension UInt64 {
    func saturatingMultiply(_ other: UInt64) -> UInt64 {
        multipliedReportingOverflow(by: other).partialValue
    }
}
