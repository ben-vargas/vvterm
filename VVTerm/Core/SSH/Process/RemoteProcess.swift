import Foundation

/// One non-interactive SSH exec channel. Drain both streams concurrently when streaming.
/// A slow consumer fails explicitly once its 16-chunk queue is full.
actor RemoteProcess {
    nonisolated let stdout: AsyncThrowingStream<Data, Error>
    nonisolated let stderr: AsyncThrowingStream<Data, Error>
    private let id: UUID
    private let session: SSHSession
    private var result: Result<RemoteProcessResult, RemoteProcessFailure>?
    private var waiters: [CheckedContinuation<RemoteProcessResult, Error>] = []

    init(id: UUID, session: SSHSession, stdout: AsyncThrowingStream<Data, Error>,
         stderr: AsyncThrowingStream<Data, Error>) {
        self.id = id
        self.session = session
        self.stdout = stdout
        self.stderr = stderr
    }

    func writeStdin(_ data: Data) async throws {
        if let result {
            switch result {
            case .failure(let failure): throw failure
            case .success: throw RemoteProcessFailure(reason: .stdinClosed, dispatch: .dispatched)
            }
        }
        try await session.writeProcessStdin(id, data: data)
    }

    func closeStdin() async { await session.closeProcessStdin(id) }

    func wait() async throws -> RemoteProcessResult {
        try await withTaskCancellationHandler {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() async { await session.cancelProcess(id, reason: .cancelled) }

    func complete(_ result: Result<RemoteProcessResult, RemoteProcessFailure>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result.mapError { $0 as Error }) }
    }
}
