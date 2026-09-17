import Foundation

extension SSHSession {
    enum ProcessMode {
        case streaming
        case collected
        case legacy(SSHExecOutputBudget)
    }

    /// All native pointers and mutable I/O state stay on SSHSession's actor.
    final class ExecRequest {
        enum Stage { case opening, pty, starting, dispatching, running }
        enum InputState { case open, closing, closed }
        let command: String
        let pty: RemotePTYRequest?
        let process: RemoteProcess
        let stdoutStream: AsyncThrowingStream<Data, Error>.Continuation
        let stderrStream: AsyncThrowingStream<Data, Error>.Continuation
        var mode: ProcessMode
        var channel: OpaquePointer?
        var stage: Stage = .opening
        var dispatch: RemoteDispatchCertainty {
            switch stage {
            case .opening, .pty, .starting: .notDispatched
            case .dispatching: .unknown
            case .running: .dispatched
            }
        }
        var stdout: RemoteProcessOutputBuffer
        var stderr: RemoteProcessOutputBuffer
        var input: Data
        var inputOffset = 0
        var inputWaiter: CheckedContinuation<Void, Error>?
        var inputState: InputState
        var timeoutTask: Task<Void, Never>?

        init(request: RemoteProcessRequest, rendered: RenderedRemoteProcess,
             process: RemoteProcess, stdoutStream: AsyncThrowingStream<Data, Error>.Continuation,
             stderrStream: AsyncThrowingStream<Data, Error>.Continuation, mode: ProcessMode) {
            command = rendered.command
            pty = request.pty
            self.process = process
            self.stdoutStream = stdoutStream
            self.stderrStream = stderrStream
            self.mode = mode
            stdout = RemoteProcessOutputBuffer(limit: request.outputLimit.stdoutBytes)
            stderr = RemoteProcessOutputBuffer(limit: request.outputLimit.stderrBytes)
            input = rendered.stdin ?? Data()
            switch mode {
            case .legacy: inputState = .open
            case .collected: inputState = .closing
            case .streaming: inputState = rendered.closesStdin ? .closing : .open
            }
        }
    }

    func startProcess(_ request: RemoteProcessRequest, shell: RemoteShellProfile,
                      mode: ProcessMode = .streaming) throws -> RemoteProcess {
        guard !Task.isCancelled else { throw RemoteProcessFailure(reason: .cancelled, dispatch: .notDispatched) }
        let rendered = try RemoteProcessRenderer.render(request, shell: shell)
        guard isActive, libssh2Session != nil else { throw RemoteProcessFailure(reason: .notConnected, dispatch: .notDispatched) }
        let id = UUID()
        let stdout = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let stderr = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let process = RemoteProcess(id: id, session: self, stdout: stdout.stream, stderr: stderr.stream)
        let state = ExecRequest(request: request, rendered: rendered, process: process,
                                stdoutStream: stdout.continuation, stderrStream: stderr.continuation,
                                mode: mode)
        execRequests[id] = state
        state.timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: request.timeout) } catch { return }
            await self?.cancelProcess(id, reason: .timeout)
        }
        startIOLoop()
        return process
    }

    func writeProcessStdin(_ id: UUID, data: Data) async throws {
        guard let state = execRequests[id], state.inputState == .open else {
            throw RemoteProcessFailure(reason: .stdinClosed, dispatch: .unknown)
        }
        guard data.count <= 1_048_576 else { throw RemoteProcessFailure(reason: .invalidRequest, dispatch: state.dispatch) }
        guard state.input.isEmpty, state.inputWaiter == nil else {
            throw RemoteProcessFailure(reason: .stdinBusy, dispatch: state.dispatch)
        }
        guard !data.isEmpty else { return }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                state.input = data
                state.inputOffset = 0
                state.inputWaiter = continuation
            }
        } onCancel: {
            Task { await self.cancelProcess(id, reason: .cancelled) }
        }
    }

    func closeProcessStdin(_ id: UUID) {
        guard let state = execRequests[id], state.inputState == .open else { return }
        state.inputState = .closing
    }

    func cancelProcess(_ id: UUID, reason: RemoteProcessFailure.Reason) async {
        await finishProcess(id, reason: reason)
    }
}
