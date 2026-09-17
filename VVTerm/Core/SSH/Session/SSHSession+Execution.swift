import Foundation
import os.log

extension SSHSession {
    func failAllExecRequests() {
        let requests = execRequests
        execRequests.removeAll()
        for request in requests.values {
            request.channel = nil // Session teardown owns these native channels.
            request.timeoutTask?.cancel()
            let failure = RemoteProcessFailure(reason: .notConnected, dispatch: request.dispatch)
            request.stdoutStream.finish(throwing: failure)
            request.stderrStream.finish(throwing: failure)
            request.inputWaiter?.resume(throwing: failure)
            request.inputWaiter = nil
            let process = request.process
            Task { await process.complete(.failure(failure)) }
        }
    }

    func execute(_ command: String, maxOutputBytes: Int = SSHExecOutputBudget.defaultMaximumBytes) async throws -> String {
        try await executeResult(command, maxOutputBytes: maxOutputBytes).output
    }

    func executeResult(_ command: String, maxOutputBytes: Int = SSHExecOutputBudget.defaultMaximumBytes) async throws -> SSHCommandResult {
        let maximum = max(0, maxOutputBytes)
        var request = RemoteProcessRequest(payload: .rawShell(shell: .unknown, command: command, reason: .compatibility))
        // The client retains ownership of legacy command-versus-connection deadlines.
        request.timeout = .seconds(86_400)
        request.outputLimit = .init(stdoutBytes: min(maximum, 67_108_864), stderrBytes: min(maximum, 67_108_864))
        do {
            let process = try startProcess(request, shell: .unknown(), mode: .legacy(SSHExecOutputBudget(maximumBytes: maximum)))
            let result = try await process.wait()
            guard !result.stdoutTruncated, !result.stderrTruncated else { throw SSHError.outputLimitExceeded }
            return SSHCommandResult(output: String(data: result.stdout, encoding: .utf8) ?? "",
                                    exitStatus: result.exitStatus.map { Int32(bitPattern: $0) } ?? -1)
        } catch let failure as RemoteProcessFailure {
            switch failure.reason {
            case .cancelled: throw CancellationError()
            case .timeout: throw SSHError.timeout
            case .notConnected: throw SSHError.notConnected
            case .channelOpen: throw SSHError.channelOpenFailed
            case .outputOverflow: throw SSHError.outputLimitExceeded
            case .transport: throw SSHError.socketError("Remote command transport failed")
            default: throw SSHError.unknown("Remote command failed")
            }
        }
    }

    func finishProcess(_ id: UUID, reason: RemoteProcessFailure.Reason?) async {
        guard let state = execRequests.removeValue(forKey: id) else { return }
        state.timeoutTask?.cancel()
        var status: UInt32?
        var signal: String?
        if let channel = state.channel, reason == nil {
            if libssh2_channel_has_exit_status(channel) != 0 {
                status = UInt32(bitPattern: libssh2_channel_get_exit_status(channel))
            }
            var value: UnsafeMutablePointer<CChar>?
            var count = 0
            if libssh2_channel_get_exit_signal(channel, &value, &count, nil, nil, nil, nil) == 0,
               let value, let session = libssh2Session {
                signal = String(decoding: UnsafeRawBufferPointer(start: value, count: count), as: UTF8.self)
                libssh2_free(session, value)
            }
        }
        var failure = reason.map { RemoteProcessFailure(reason: $0, dispatch: state.dispatch) }
        state.inputWaiter?.resume(throwing: failure ?? RemoteProcessFailure(reason: .stdinClosed, dispatch: state.dispatch))
        state.inputWaiter = nil
        if let channel = state.channel, let session = libssh2Session {
            state.channel = nil
            execCleanupsInFlight.insert(id)
            // Keep the session allocation alive across cleanup's actor suspensions.
            _ = await completeActiveChannelCleanupCall(session: session) { libssh2_channel_close(channel) }
            let freeResult = await completeActiveChannelCleanupCall(session: session) { libssh2_channel_free(channel) }
            if freeResult != 0, isActive {
                // A failed native release cannot be left attached to a live transport.
                logger.error("Process channel cleanup failed: \(freeResult)")
                failure = failure ?? RemoteProcessFailure(reason: .transport, dispatch: state.dispatch)
                invalidateTransport()
            }
            execCleanupsInFlight.remove(id)
            if !isActive { cleanupLibssh2() }
        }
        if let failure {
            state.stdoutStream.finish(throwing: failure)
            state.stderrStream.finish(throwing: failure)
            await state.process.complete(.failure(failure))
        } else {
            state.stdoutStream.finish()
            state.stderrStream.finish()
            await state.process.complete(.success(.init(stdout: state.stdout.data, stderr: state.stderr.data,
                exitStatus: status, exitSignal: signal, stdoutTruncated: state.stdout.truncated,
                stderrTruncated: state.stderr.truncated)))
        }
    }
}
