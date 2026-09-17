import Foundation

nonisolated struct RemoteProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitStatus: UInt32?
    let exitSignal: String?
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
}

nonisolated enum RemoteDispatchCertainty: Sendable { case notDispatched, dispatched, unknown }

/// Messages deliberately exclude command text, stdin, environment, and remote output.
nonisolated struct RemoteProcessFailure: Error, Sendable {
    enum Reason: Sendable {
        case invalidRequest, unsupportedShell, notConnected, channelOpen, startup
        case transport, timeout, cancelled, outputOverflow, stdinClosed, stdinBusy
    }
    let reason: Reason
    let dispatch: RemoteDispatchCertainty
}
