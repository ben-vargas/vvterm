import Foundation

struct SFTPRemoteFileService: RemoteFileService {
    let client: SSHClient

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry] {
        try await client.listDirectory(at: path, maxEntries: maxEntries)
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        try await client.stat(at: path)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        try await client.lstat(at: path)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        try await client.readFile(at: path, maxBytes: maxBytes)
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        try await client.downloadFile(at: path, to: localURL)
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await client.upload(
            data,
            to: remotePath,
            permissions: permissions,
            strategy: strategy
        )
    }

    func createDirectory(at path: String, permissions: Int32) async throws {
        try await client.createDirectory(at: path, permissions: permissions)
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        try await client.renameItem(at: sourcePath, to: destinationPath)
    }

    func deleteFile(at path: String) async throws {
        try await client.deleteFile(at: path)
    }

    func deleteDirectory(at path: String) async throws {
        try await client.deleteDirectory(at: path)
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        try await client.setPermissions(at: path, permissions: permissions)
    }

    func resolveHomeDirectory() async throws -> String {
        try await client.resolveHomeDirectory()
    }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        try await client.fileSystemStatus(at: path)
    }
}
