import Foundation
import OSLog

actor RemoteClipboardTransferService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "RemoteClipboardTransfer")
    private let sessionId: UUID
    private var didSweepStaleFiles = false

    init(sessionId: UUID) {
        self.sessionId = sessionId
    }

    func upload(
        _ attachment: TerminalAttachmentPayload,
        using sshClient: SSHClient
    ) async throws -> RemoteClipboardUpload {
        try Task.checkCancellation()
        let environment = await sshClient.remoteEnvironment()
        try Task.checkCancellation()
        logger.info(
            "Preparing remote upload [session: \(self.sessionId.uuidString, privacy: .public)] [platform: \(environment.platform.rawValue, privacy: .public)] [shell: \(environment.shellProfile.family.rawValue, privacy: .public)] [bytes: \(attachment.sizeBytes)]"
        )
        let plan = try RemoteClipboardTransferPlan.resolve(for: environment)

        let remotePath: String
        do {
            remotePath = try await createRemoteTemporaryPath(
                extension: attachment.suggestedExtension,
                plan: plan,
                using: sshClient
            )
        } catch {
            logger.error(
                "Remote temp path creation failed [session: \(self.sessionId.uuidString, privacy: .public)] [error: \(LogPrivacy.errorClass(error), privacy: .public)]"
            )
            if let sshError = error as? SSHError, case .timeout = sshError {
                throw TerminalRichPasteError.remoteUploadFailed(String(localized: "timed out while creating remote temporary file"))
            }
            throw error
        }

        let transferPath: String
        let pastedPathToken: String
        do {
            transferPath = try plan.transferPath(for: remotePath)
            pastedPathToken = try plan.pastedPathToken(for: remotePath)
        } catch {
            await deleteRemoteFileIfNeeded(at: remotePath, plan: plan, using: sshClient)
            throw error
        }
        logger.info(
            "Uploading remote attachment [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(remotePath, privacy: .private(mask: .hash))] [sftp: \(plan.usesSFTP)]"
        )

        do {
            try Task.checkCancellation()
            switch plan {
            case .posix(let uploadStrategy):
                try await sshClient.upload(
                    attachment.data,
                    to: transferPath,
                    permissions: Int32(0o600),
                    strategy: uploadStrategy
                )
            case .windows:
                try await sshClient.writeFile(
                    attachment.data,
                    to: transferPath,
                    permissions: Int32(0o600)
                )
            }
            try Task.checkCancellation()
            logger.info(
                "Remote upload completed [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(remotePath, privacy: .private(mask: .hash))]"
            )
            scheduleStaleFileSweepIfNeeded(plan: plan, using: sshClient)
            return RemoteClipboardUpload(
                remotePath: remotePath,
                pastedPathToken: pastedPathToken,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes
            )
        } catch {
            logger.error(
                "Remote upload failed [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(remotePath, privacy: .private(mask: .hash))] [error: \(LogPrivacy.errorClass(error), privacy: .public)]"
            )
            await deleteRemoteFileIfNeeded(at: remotePath, plan: plan, using: sshClient)
            if error is CancellationError { throw error }
            if let sshError = error as? SSHError, case .timeout = sshError {
                throw TerminalRichPasteError.remoteUploadFailed(String(localized: "timed out while uploading file bytes"))
            }
            throw TerminalRichPasteError.remoteUploadFailed(error.localizedDescription)
        }
    }

    func delete(_ upload: RemoteClipboardUpload, using sshClient: SSHClient) async {
        guard let plan = try? RemoteClipboardTransferPlan.resolve(for: await sshClient.remoteEnvironment()) else { return }
        await deleteRemoteFileIfNeeded(at: upload.remotePath, plan: plan, using: sshClient)
    }

    private func createRemoteTemporaryPath(
        extension fileExtension: String,
        plan: RemoteClipboardTransferPlan,
        using sshClient: SSHClient
    ) async throws -> String {
        let output = try await sshClient.execute(
            plan.temporaryPathCommand(fileExtension: fileExtension)
        )
        let path = try plan.parseTemporaryPath(output)
        logger.info(
            "Created remote temp path [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(path, privacy: .private(mask: .hash))]"
        )
        return path
    }

    private func scheduleStaleFileSweepIfNeeded(
        plan: RemoteClipboardTransferPlan,
        using sshClient: SSHClient
    ) {
        guard !didSweepStaleFiles else { return }
        didSweepStaleFiles = true
        let command = plan.staleSweepCommand

        let sessionId = self.sessionId
        logger.debug("Scheduling stale clipboard temp file sweep [session: \(self.sessionId.uuidString, privacy: .public)]")

        Task(priority: .utility) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "RemoteClipboardTransfer")
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            logger.debug("Sweeping stale clipboard temp files [session: \(sessionId.uuidString, privacy: .public)]")
            do {
                _ = try await sshClient.execute(command, timeout: .seconds(2))
                logger.debug("Finished stale clipboard temp file sweep [session: \(sessionId.uuidString, privacy: .public)]")
            } catch {
                logger.debug(
                    "Skipping stale clipboard temp file sweep result [session: \(sessionId.uuidString, privacy: .public)] [error: \(LogPrivacy.errorClass(error), privacy: .public)]"
                )
            }
        }
    }

    private func deleteRemoteFileIfNeeded(
        at path: String,
        plan: RemoteClipboardTransferPlan,
        using sshClient: SSHClient
    ) async {
        guard !path.isEmpty else { return }
        logger.debug(
            "Deleting remote clipboard temp file [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(path, privacy: .private(mask: .hash))]"
        )
        await Task { _ = try? await sshClient.execute(plan.deleteCommand(for: path)) }.value
    }
}
