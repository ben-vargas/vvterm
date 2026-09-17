import Foundation

nonisolated struct RemoteProcessRequest: Sendable {
    let payload: RemoteExecutionPayload
    var environment: [String: String] = [:]
    var workingDirectory: String?
    var stdin: Data?
    var pty: RemotePTYRequest?
    var timeout: Duration = .seconds(20)
    var outputLimit = RemoteProcessOutputLimit()
    var sensitivity: RemotePayloadSensitivity = .sensitive
}

nonisolated enum RemoteExecutionPayload: Sendable {
    case invocation(RemoteInvocation)
    case script(RemoteScript)
    case rawShell(shell: RemoteShellFamily, command: String, reason: RawShellReason)
}

nonisolated struct RemoteInvocation: Sendable {
    let executable: String
    var arguments: [String] = []
}

nonisolated struct RemoteScript: Sendable {
    let shell: RemoteShellFamily
    let source: Data
}

nonisolated struct RemotePTYRequest: Sendable {
    var terminal = "xterm-256color"
    var columns: Int32 = 80
    var rows: Int32 = 24
}

nonisolated enum RawShellReason: Sendable { case compatibility, userCommand, unsupportedIntegration }
nonisolated enum RemotePayloadSensitivity: Sendable { case sensitive, publicMetadata }

nonisolated struct RemoteProcessOutputLimit: Sendable {
    var stdoutBytes: Int = 1_048_576
    var stderrBytes: Int = 1_048_576
}
