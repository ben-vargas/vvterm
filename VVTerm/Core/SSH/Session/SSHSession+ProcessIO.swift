import Foundation

extension SSHSession {
    func advanceProcess(_ id: UUID, buffer: inout [CChar]) async -> Bool {
        guard let state = execRequests[id], let session = libssh2Session else { return false }
        switch state.stage {
        case .opening:
            if let channel = libssh2_channel_open_ex(session, "session", 7, 2 * 1_024 * 1_024, 32_768, nil, 0) {
                state.channel = channel
                state.stage = state.pty == nil ? .starting : .pty
                return true
            }
            if libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN {
                await finishProcess(id, reason: .channelOpen)
            }
            return false
        case .pty:
            guard let channel = state.channel, let pty = state.pty else { return false }
            let result = libssh2_channel_request_pty_ex(channel, pty.terminal, UInt32(pty.terminal.utf8.count),
                                                       nil, 0, pty.columns, pty.rows, 0, 0)
            if result == 0 { state.stage = .starting; return true }
            if result != LIBSSH2_ERROR_EAGAIN { await finishProcess(id, reason: .startup) }
            return false
        case .starting, .dispatching:
            guard let channel = state.channel else { return false }
            // EAGAIN can mean the server received exec but its reply has not arrived.
            state.stage = .dispatching
            let result = libssh2_channel_process_startup(channel, "exec", 4, state.command, UInt32(state.command.utf8.count))
            if result == 0 {
                state.stage = .running
                return true
            }
            if result != LIBSSH2_ERROR_EAGAIN { await finishProcess(id, reason: .startup) }
            return false
        case .running: break
        }
        guard let channel = state.channel else { return false }
        var didWork = false
        if !state.input.isEmpty {
            let count = min(32_768, state.input.count - state.inputOffset)
            let written = state.input.withUnsafeBytes { bytes in
                libssh2_channel_write_ex(channel, 0,
                    bytes.baseAddress!.advanced(by: state.inputOffset).assumingMemoryBound(to: CChar.self), count)
            }
            if written > 0 {
                state.inputOffset += written
                didWork = true
                if state.inputOffset == state.input.count {
                    state.input = Data()
                    state.inputOffset = 0
                    state.inputWaiter?.resume()
                    state.inputWaiter = nil
                }
            } else if written != 0, written != LIBSSH2_ERROR_EAGAIN {
                await finishProcess(id, reason: .transport)
                return true
            }
        }
        if state.input.isEmpty, state.inputState == .closing {
            let result = libssh2_channel_send_eof(channel)
            if result == 0 { state.inputState = .closed; didWork = true }
            else if result != LIBSSH2_ERROR_EAGAIN {
                await finishProcess(id, reason: .transport)
                return true
            }
        }
        var received = false
        for streamID: Int32 in [0, 1] {
            let count = libssh2_channel_read_ex(channel, streamID, &buffer, buffer.count)
            if count > 0 {
                received = true
                didWork = true
                if case .legacy(var budget) = state.mode {
                    guard budget.reserve(count) else {
                        await finishProcess(id, reason: .outputOverflow)
                        return true
                    }
                    state.mode = .legacy(budget)
                }
                let bytes = Data(bytes: buffer, count: count)
                if streamID == 0 { state.stdout.append(bytes) }
                else { state.stderr.append(bytes) }
                if case .streaming = state.mode {
                    let continuation = streamID == 0 ? state.stdoutStream : state.stderrStream
                    switch continuation.yield(bytes) {
                    case .enqueued: break
                    case .dropped:
                        await finishProcess(id, reason: .outputOverflow)
                        return true
                    case .terminated:
                        await finishProcess(id, reason: .cancelled)
                        return true
                    @unknown default:
                        await finishProcess(id, reason: .transport)
                        return true
                    }
                }
            } else if count < 0, count != LIBSSH2_ERROR_EAGAIN {
                await finishProcess(id, reason: .transport)
                return true
            }
        }
        // Drain buffered data before collecting status, even if EOF already arrived.
        if !received, libssh2_channel_eof(channel) != 0 {
            let result = libssh2_channel_wait_closed(channel)
            if result == 0 { await finishProcess(id, reason: nil); return true }
            if result != LIBSSH2_ERROR_EAGAIN { await finishProcess(id, reason: .transport); return true }
        }
        return didWork
    }
}
