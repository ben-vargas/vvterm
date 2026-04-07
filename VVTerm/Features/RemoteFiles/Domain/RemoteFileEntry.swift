import Foundation

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

    var supportsPreview: Bool {
        type != .directory
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
