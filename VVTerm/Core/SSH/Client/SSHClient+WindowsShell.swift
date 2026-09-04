import Foundation
import os.log

extension SSHClient {
    func prepareWindowsShellScript(
        _ command: String?,
        environment: RemoteEnvironment,
        using expectedSession: SSHSession
    ) async throws -> WindowsShellScript? {
        guard let command, WindowsShellScript.needsTransfer(command: command, environment: environment) else {
            return nil
        }
        var script: WindowsShellScript?
        do {
            let directory = try await Self.runWithDeadline(.seconds(10)) {
                try await expectedSession.resolveHomeDirectory()
            }
            try validateShellStartupSessionBeforeShellRequest(expectedSession)
            let prepared = try WindowsShellScript(command: command, homeDirectory: directory)
            // Bound the actual encoded launcher, including escaped path characters.
            guard !WindowsShellScript.needsTransfer(command: prepared.launcher, environment: environment) else {
                throw SFTPTransportError.invalidEntryName
            }
            script = prepared
            try await Self.runWithDeadline(.seconds(10)) {
                try await expectedSession.writeFile(prepared.contents, to: prepared.remotePath, permissions: 0o600)
            }
            try validateShellStartupSessionBeforeShellRequest(expectedSession)
            return prepared
        } catch {
            if let script { await removeWindowsShellScript(script, using: expectedSession) }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SSHShellPreparationError(underlying: error)
        }
    }

    func removeWindowsShellScript(_ script: WindowsShellScript, using session: SSHSession) async {
        // A cancelled launch still needs a bounded attempt to remove its partial file.
        let removed = await Task { @concurrent in
            do {
                try await Self.runWithDeadline(.seconds(2)) {
                    try await session.deleteFile(at: script.remotePath)
                }
                return true
            } catch { return false }
        }.value
        if !removed { logger.warning("Unable to remove the temporary remote startup script") }
    }
}
