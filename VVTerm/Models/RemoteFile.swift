import Foundation
import UniformTypeIdentifiers

enum RemoteFileType: String, Codable, CaseIterable, Sendable {
    case file
    case directory
    case symlink
    case other

    var displayName: String {
        switch self {
        case .file:
            return String(localized: "File")
        case .directory:
            return String(localized: "Directory")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Other")
        }
    }
}

enum RemoteFilePermissionAudience: String, CaseIterable, Identifiable, Sendable {
    case owner
    case group
    case everyone

    var id: String { rawValue }
}

enum RemoteFilePermissionCapability: String, CaseIterable, Identifiable, Sendable {
    case read
    case write
    case execute

    var id: String { rawValue }

    func bit(for audience: RemoteFilePermissionAudience) -> UInt32 {
        switch (audience, self) {
        case (.owner, .read):
            return UInt32(LIBSSH2_SFTP_S_IRUSR)
        case (.owner, .write):
            return UInt32(LIBSSH2_SFTP_S_IWUSR)
        case (.owner, .execute):
            return UInt32(LIBSSH2_SFTP_S_IXUSR)
        case (.group, .read):
            return UInt32(LIBSSH2_SFTP_S_IRGRP)
        case (.group, .write):
            return UInt32(LIBSSH2_SFTP_S_IWGRP)
        case (.group, .execute):
            return UInt32(LIBSSH2_SFTP_S_IXGRP)
        case (.everyone, .read):
            return UInt32(LIBSSH2_SFTP_S_IROTH)
        case (.everyone, .write):
            return UInt32(LIBSSH2_SFTP_S_IWOTH)
        case (.everyone, .execute):
            return UInt32(LIBSSH2_SFTP_S_IXOTH)
        }
    }
}

struct RemoteFilePermissionDraft: Equatable, Sendable {
    private var bits: UInt32

    init(accessBits: UInt32) {
        bits = accessBits & 0o777
    }

    init(entry: RemoteFileEntry) {
        self.init(accessBits: entry.permissions ?? 0)
    }

    var accessBits: UInt32 {
        bits & 0o777
    }

    var octalSummary: String {
        let octal = String(accessBits, radix: 8)
        return String(repeating: "0", count: max(0, 3 - octal.count)) + octal
    }

    var symbolicSummary: String {
        RemoteFileEntry.symbolicPermissions(for: accessBits)
    }

    func isEnabled(_ capability: RemoteFilePermissionCapability, for audience: RemoteFilePermissionAudience) -> Bool {
        accessBits & capability.bit(for: audience) != 0
    }

    mutating func set(
        _ isEnabled: Bool,
        capability: RemoteFilePermissionCapability,
        for audience: RemoteFilePermissionAudience
    ) {
        let bit = capability.bit(for: audience)
        if isEnabled {
            bits |= bit
        } else {
            bits &= ~bit
        }
    }
}

struct RemoteFileEntry: Identifiable, Hashable, Codable, Sendable {
    let name: String
    let path: String
    let type: RemoteFileType
    let size: UInt64?
    let modifiedAt: Date?
    let permissions: UInt32?
    let symlinkTarget: String?

    var id: String { path }

    var isHidden: Bool {
        name.hasPrefix(".") && name != "." && name != ".."
    }

    var iconName: String {
        switch type {
        case .directory:
            return "folder.fill"
        case .symlink:
            return "link"
        case .other:
            return "questionmark.square.dashed"
        case .file:
            let lowercasedExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
            switch lowercasedExtension {
            case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg":
                return "photo"
            case "mov", "mp4", "mkv", "avi":
                return "film"
            case "zip", "tar", "gz", "tgz", "xz", "bz2":
                return "archivebox"
            case "log", "txt", "md", "json", "yaml", "yml", "toml", "xml", "plist", "ini", "conf", "config", "swift", "sh", "zsh", "bash", "py", "rb", "js", "ts", "tsx", "jsx", "html", "css", "sql":
                return "doc.text"
            default:
                return "doc"
            }
        }
    }

    var metadataTypeLabel: String {
        type.displayName
    }

    var sortableModifiedAt: Date {
        modifiedAt ?? .distantPast
    }

    var sortableSize: UInt64 {
        size ?? 0
    }

    var formattedPermissions: String? {
        guard let permissions else { return nil }
        let octal = String(permissions & 0o7777, radix: 8)
        let padded = String(repeating: "0", count: max(0, 4 - octal.count)) + octal
        return "\(padded) (\(Self.symbolicPermissions(for: permissions)))"
    }

    var specialPermissionBits: UInt32 {
        (permissions ?? 0) & 0o7000
    }

    static func symbolicPermissions(for permissions: UInt32) -> String {
        func bits(_ read: UInt32, _ write: UInt32, _ execute: UInt32) -> String {
            [
                permissions & read != 0 ? "r" : "-",
                permissions & write != 0 ? "w" : "-",
                permissions & execute != 0 ? "x" : "-"
            ].joined()
        }

        return [
            bits(UInt32(LIBSSH2_SFTP_S_IRUSR), UInt32(LIBSSH2_SFTP_S_IWUSR), UInt32(LIBSSH2_SFTP_S_IXUSR)),
            bits(UInt32(LIBSSH2_SFTP_S_IRGRP), UInt32(LIBSSH2_SFTP_S_IWGRP), UInt32(LIBSSH2_SFTP_S_IXGRP)),
            bits(UInt32(LIBSSH2_SFTP_S_IROTH), UInt32(LIBSSH2_SFTP_S_IWOTH), UInt32(LIBSSH2_SFTP_S_IXOTH))
        ].joined()
    }

    static func from(
        name: String,
        path: String,
        attributes: LIBSSH2_SFTP_ATTRIBUTES,
        symlinkTarget: String? = nil
    ) -> RemoteFileEntry {
        let flags = UInt32(attributes.flags)
        let permissionBits = UInt32(attributes.permissions)
        let type = Self.fileType(from: permissionBits, flags: flags)
        let size = flags & UInt32(LIBSSH2_SFTP_ATTR_SIZE) != 0
            ? UInt64(attributes.filesize)
            : nil
        let modifiedAt = flags & UInt32(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
            ? Date(timeIntervalSince1970: TimeInterval(attributes.mtime))
            : nil
        let permissions = flags & UInt32(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
            ? permissionBits
            : nil

        return RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: size,
            modifiedAt: modifiedAt,
            permissions: permissions,
            symlinkTarget: symlinkTarget
        )
    }

    private static func fileType(from permissions: UInt32, flags: UInt32) -> RemoteFileType {
        guard flags & UInt32(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 else {
            return .other
        }

        let typeMask = permissions & UInt32(LIBSSH2_SFTP_S_IFMT)
        switch typeMask {
        case UInt32(LIBSSH2_SFTP_S_IFDIR):
            return .directory
        case UInt32(LIBSSH2_SFTP_S_IFLNK):
            return .symlink
        case UInt32(LIBSSH2_SFTP_S_IFREG):
            return .file
        default:
            return .other
        }
    }
}

enum RemoteFileSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case name
    case modifiedAt
    case size

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:
            return String(localized: "Name")
        case .modifiedAt:
            return String(localized: "Date Modified")
        case .size:
            return String(localized: "Size")
        }
    }

    var defaultDirection: RemoteFileSortDirection {
        switch self {
        case .name:
            return .ascending
        case .modifiedAt, .size:
            return .descending
        }
    }
}

enum RemoteFileSortDirection: String, Codable, Sendable {
    case ascending
    case descending

    init(sortOrder: SortOrder) {
        switch sortOrder {
        case .forward:
            self = .ascending
        case .reverse:
            self = .descending
        }
    }

    var sortOrder: SortOrder {
        switch self {
        case .ascending:
            return .forward
        case .descending:
            return .reverse
        }
    }
}

struct RemoteFileViewerPayload: Identifiable, Hashable, Sendable {
    let previewKind: RemoteFilePreviewKind
    let entry: RemoteFileEntry
    let textPreview: String?
    let previewFileURL: URL?
    let isTruncated: Bool
    let unavailableMessage: String?
    let requiresExplicitDownload: Bool
    let previewByteCount: UInt64?

    var id: String { entry.id }

    var isInlinePreviewAvailable: Bool {
        previewKind != .unavailable && !requiresExplicitDownload
    }

    var canEditText: Bool {
        previewKind == .text && textPreview != nil && !isTruncated
    }
}

enum RemoteFilePreviewKind: Hashable, Sendable {
    case text
    case image
    case video
    case unavailable
}

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

private extension UInt64 {
    func saturatingMultiply(_ other: UInt64) -> UInt64 {
        multipliedReportingOverflow(by: other).partialValue
    }
}

struct RemoteFileBreadcrumb: Identifiable, Hashable, Sendable {
    let title: String
    let path: String

    var id: String { path }
}

struct RemoteFileBrowserPersistedState: Codable, Hashable, Sendable {
    var lastVisitedPath: String?
    var sort: RemoteFileSort
    var sortDirection: RemoteFileSortDirection
    var showHiddenFiles: Bool
    var hasCustomizedHiddenFiles: Bool

    init(
        lastVisitedPath: String? = nil,
        sort: RemoteFileSort = .name,
        sortDirection: RemoteFileSortDirection? = nil,
        showHiddenFiles: Bool = true,
        hasCustomizedHiddenFiles: Bool = false
    ) {
        self.lastVisitedPath = lastVisitedPath
        self.sort = sort
        self.sortDirection = sortDirection ?? sort.defaultDirection
        self.showHiddenFiles = showHiddenFiles
        self.hasCustomizedHiddenFiles = hasCustomizedHiddenFiles
    }

    private enum CodingKeys: String, CodingKey {
        case lastVisitedPath
        case sort
        case sortDirection
        case showHiddenFiles
        case hasCustomizedHiddenFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sort = try container.decodeIfPresent(RemoteFileSort.self, forKey: .sort) ?? .name
        lastVisitedPath = try container.decodeIfPresent(String.self, forKey: .lastVisitedPath)
        self.sort = sort
        sortDirection = try container.decodeIfPresent(RemoteFileSortDirection.self, forKey: .sortDirection) ?? sort.defaultDirection
        hasCustomizedHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .hasCustomizedHiddenFiles) ?? false
        if hasCustomizedHiddenFiles {
            showHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? true
        } else {
            showHiddenFiles = true
        }
    }
}

enum RemoteFileBrowserError: LocalizedError, Identifiable, Equatable, Sendable {
    case permissionDenied
    case pathNotFound
    case disconnected
    case unsupportedEncoding
    case failed(String)

    var id: String {
        switch self {
        case .permissionDenied:
            return "permissionDenied"
        case .pathNotFound:
            return "pathNotFound"
        case .disconnected:
            return "disconnected"
        case .unsupportedEncoding:
            return "unsupportedEncoding"
        case .failed(let message):
            return "failed:\(message)"
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Permission denied.")
        case .pathNotFound:
            return String(localized: "The remote path could not be found.")
        case .disconnected:
            return String(localized: "The remote connection was interrupted.")
        case .unsupportedEncoding:
            return String(localized: "Inline preview is unavailable for this file.")
        case .failed(let message):
            return message
        }
    }

    static func map(_ error: Error) -> RemoteFileBrowserError {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = message.lowercased()

        if lowercased.contains("permission denied") || lowercased.contains("ssh_fx_permission_denied") {
            return .permissionDenied
        }
        if lowercased.contains("not found") || lowercased.contains("no such file") || lowercased.contains("ssh_fx_no_such_file") {
            return .pathNotFound
        }
        if lowercased.contains("not connected") || lowercased.contains("timed out") || lowercased.contains("timeout") || lowercased.contains("disconnect") {
            return .disconnected
        }

        return .failed(message.isEmpty ? String(localized: "The file browser request failed.") : message)
    }
}

enum RemoteFilePath {
    static func normalize(_ path: String, relativeTo currentPath: String? = nil) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return currentPath ?? "/"
        }

        let basePath: String
        if trimmed.hasPrefix("/") {
            basePath = trimmed
        } else if let currentPath {
            let separator = currentPath == "/" ? "" : "/"
            basePath = currentPath + separator + trimmed
        } else {
            basePath = "/" + trimmed
        }

        let components = basePath.split(separator: "/", omittingEmptySubsequences: false)
        var normalized: [Substring] = []

        for component in components {
            switch component {
            case "", ".":
                continue
            case "..":
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
            default:
                normalized.append(component)
            }
        }

        return "/" + normalized.joined(separator: "/")
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }

        var components = normalized.split(separator: "/")
        _ = components.popLast()
        if components.isEmpty {
            return "/"
        }
        return "/" + components.joined(separator: "/")
    }

    static func appending(_ name: String, to directoryPath: String) -> String {
        let separator = directoryPath == "/" ? "" : "/"
        return normalize(directoryPath + separator + name)
    }

    static func breadcrumbs(for path: String) -> [RemoteFileBreadcrumb] {
        let normalized = normalize(path)
        guard normalized != "/" else {
            return [RemoteFileBreadcrumb(title: "/", path: "/")]
        }

        var breadcrumbs = [RemoteFileBreadcrumb(title: "/", path: "/")]
        let components = normalized.split(separator: "/")
        var current = ""
        for component in components {
            current += "/" + component
            breadcrumbs.append(
                RemoteFileBreadcrumb(title: String(component), path: current)
            )
        }
        return breadcrumbs
    }
}

enum RemoteFilePreviewDetector {
    private static let nullByte = UInt8(ascii: "\0")

    static func previewKind(for entry: RemoteFileEntry, data: Data) -> RemoteFilePreviewKind {
        if decodeTextPreview(from: data) != nil {
            return .text
        }

        guard let contentType = contentType(for: entry) else {
            return .unavailable
        }

        if contentType.conforms(to: .image) {
            return .image
        }

        if contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) {
            return .video
        }

        return .unavailable
    }

    static func decodeTextPreview(from data: Data) -> String? {
        guard isProbablyText(data) else { return nil }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let utf16LittleEndian = String(data: data, encoding: .utf16LittleEndian) {
            return utf16LittleEndian
        }

        if let utf16BigEndian = String(data: data, encoding: .utf16BigEndian) {
            return utf16BigEndian
        }

        return nil
    }

    static func isProbablyText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }

        let sample = data.prefix(1024)
        let nullCount = sample.filter { $0 == nullByte }.count
        if nullCount > 0 {
            return false
        }

        if String(data: sample, encoding: .utf8) != nil {
            return true
        }

        return String(data: sample, encoding: .utf16LittleEndian) != nil
            || String(data: sample, encoding: .utf16BigEndian) != nil
    }

    private static func contentType(for entry: RemoteFileEntry) -> UTType? {
        let fileExtension = URL(fileURLWithPath: entry.name).pathExtension
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)
    }
}

extension Array where Element == RemoteFileEntry {
    func sortedForBrowser(using sort: RemoteFileSort, direction: RemoteFileSortDirection) -> [RemoteFileEntry] {
        sorted { lhs, rhs in
            let lhsDirectoryRank = lhs.type == .directory ? 0 : 1
            let rhsDirectoryRank = rhs.type == .directory ? 0 : 1
            if lhsDirectoryRank != rhsDirectoryRank {
                return lhsDirectoryRank < rhsDirectoryRank
            }

            switch sort {
            case .name:
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison != .orderedSame {
                    return direction == .ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            case .modifiedAt:
                let lhsDate = lhs.modifiedAt ?? .distantPast
                let rhsDate = rhs.modifiedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return direction == .ascending ? lhsDate < rhsDate : lhsDate > rhsDate
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                let lhsSize = lhs.size ?? 0
                let rhsSize = rhs.size ?? 0
                if lhsSize != rhsSize {
                    return direction == .ascending ? lhsSize < rhsSize : lhsSize > rhsSize
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
