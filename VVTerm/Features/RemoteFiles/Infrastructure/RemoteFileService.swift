import Foundation

protocol RemoteFileService {
    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry]
    func stat(at path: String) async throws -> RemoteFileEntry
    func lstat(at path: String) async throws -> RemoteFileEntry
    func readFile(at path: String, maxBytes: Int) async throws -> Data
    func downloadFile(at path: String, to localURL: URL) async throws
    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws
    func createDirectory(at path: String, permissions: Int32) async throws
    func renameItem(at sourcePath: String, to destinationPath: String) async throws
    func deleteFile(at path: String) async throws
    func deleteDirectory(at path: String) async throws
    func setPermissions(at path: String, permissions: UInt32) async throws
    func resolveHomeDirectory() async throws -> String
    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus
}
