import Foundation

extension SSHClient {
    nonisolated enum ExecTimeoutScope: Sendable {
        case command
        case connection
    }
    // MARK: - Command Execution

    func execute(
        _ command: String,
        timeout: Duration? = nil,
        maxOutputBytes: Int = SSHExecOutputBudget.defaultMaximumBytes,
        timeoutScope: ExecTimeoutScope = .connection
    ) async throws -> String {
        try await executeResult(command, timeout: timeout, maxOutputBytes: maxOutputBytes,
                                timeoutScope: timeoutScope).output
    }

    @discardableResult
    func executeChecked(
        _ command: String,
        timeout: Duration? = nil,
        maxOutputBytes: Int = SSHExecOutputBudget.defaultMaximumBytes
    ) async throws -> String {
        let result = try await executeResult(command, timeout: timeout, maxOutputBytes: maxOutputBytes,
                                             timeoutScope: .command)
        try result.requireSuccess()
        return result.output
    }

    private func executeResult(
        _ command: String,
        timeout: Duration?,
        maxOutputBytes: Int,
        timeoutScope: ExecTimeoutScope
    ) async throws -> SSHCommandResult {
        try Task.checkCancellation()
        guard !isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }
        let effectiveTimeout = timeout ?? execTimeout
        return try await SSHClient.runWithDeadline(
            effectiveTimeout,
            onTimeout: { if timeoutScope == .connection { session.abort() } }
        ) {
            try Task.checkCancellation()
            return try await session.executeResult(command, maxOutputBytes: maxOutputBytes)
        }
    }
}
