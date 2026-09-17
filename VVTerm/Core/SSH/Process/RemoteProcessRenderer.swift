import Foundation

nonisolated struct RenderedRemoteProcess: Sendable {
    let command: String
    let stdin: Data?
    let closesStdin: Bool
}

/// Only this boundary constructs shell syntax for typed process requests.
nonisolated enum RemoteProcessRenderer {
    static func render(_ request: RemoteProcessRequest, shell: RemoteShellProfile) throws -> RenderedRemoteProcess {
        guard request.timeout > .zero, request.timeout <= .seconds(86_400),
              (0...67_108_864).contains(request.outputLimit.stdoutBytes),
              (0...67_108_864).contains(request.outputLimit.stderrBytes),
              (request.stdin?.count ?? 0) <= 1_048_576 else { throw invalid() }
        if let pty = request.pty {
            guard pty.columns > 0, pty.rows > 0, !pty.terminal.isEmpty,
                  pty.terminal.utf8.count <= 256, !pty.terminal.contains("\0") else { throw invalid() }
        }
        var remainingTextBytes = 65_536
        func reserveText(_ text: String) throws {
            let count = text.utf8.count
            guard count <= remainingTextBytes else { throw invalid() }
            remainingTextBytes -= count
        }
        guard request.environment.count <= 1_024 else { throw invalid() }
        for (key, value) in request.environment {
            try reserveText(key)
            try reserveText(value)
            guard validEnvironmentName(key), !value.contains("\0") else { throw invalid() }
        }
        if let directory = request.workingDirectory {
            try reserveText(directory)
            guard !directory.contains("\0") else { throw invalid() }
        }
        let command: String
        var input = request.stdin
        var closesInput = false
        switch request.payload {
        case .invocation(let invocation):
            guard invocation.arguments.count <= 1_024 else { throw invalid() }
            try reserveText(invocation.executable)
            for argument in invocation.arguments { try reserveText(argument) }
            guard !invocation.executable.isEmpty,
                  !([invocation.executable] + invocation.arguments).contains(where: { $0.contains("\0") }) else { throw invalid() }
            switch shell.family {
            case .posix:
                let args = ([invocation.executable] + invocation.arguments).map(posixQuote).joined(separator: " ")
                let environment = request.environment.sorted { $0.key < $1.key }
                    .map { posixQuote("\($0.key)=\($0.value)") }.joined(separator: " ")
                let launch = environment.isEmpty ? args : "env \(environment) \(args)"
                let directory = request.workingDirectory.map { "cd -- \(posixQuote($0)) && " } ?? ""
                command = "sh -c \(posixQuote(directory + "exec " + launch))"
            case .powershell:
                // ProcessStartInfo avoids PowerShell 5's lossy native argument binding
                // for empty arguments and embedded quotes. The child inherits stdio.
                var parts = ["$i = New-Object System.Diagnostics.ProcessStartInfo",
                             "$i.UseShellExecute = $false",
                             "$i.FileName = \(powerShellQuote(invocation.executable))",
                             "$i.Arguments = \(powerShellQuote(invocation.arguments.map(windowsArgument).joined(separator: " ")))" ]
                if let directory = request.workingDirectory { parts.append("$i.WorkingDirectory = \(powerShellQuote(directory))") }
                for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
                    parts.append("$i.EnvironmentVariables[\(powerShellQuote(key))] = \(powerShellQuote(value))")
                }
                parts += ["$p = [System.Diagnostics.Process]::Start($i)", "$p.WaitForExit()", "exit $p.ExitCode"]
                command = try powerShellCommand("$ErrorActionPreference = 'Stop'; " + parts.joined(separator: "; "), shell: shell)
            case .cmd:
                guard request.environment.isEmpty, request.workingDirectory == nil else { throw unsupported() }
                let args = try ([invocation.executable] + invocation.arguments).map(cmdArgument).joined(separator: " ")
                command = "cmd.exe /d /v:off /s /c \"\(args)\""
            case .unknown: throw unsupported()
            }
        case .script(let script):
            guard request.stdin == nil, script.source.count <= 1_048_576 else { throw invalid() }
            input = script.source
            closesInput = true
            let interpreter: RemoteInvocation
            switch script.shell {
            case .posix: interpreter = .init(executable: "sh", arguments: ["-s"])
            case .powershell:
                interpreter = .init(executable: try powerShellExecutable(shell),
                    arguments: ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "-"])
            case .cmd, .unknown: throw unsupported()
            }
            var invocation = RemoteProcessRequest(payload: .invocation(interpreter))
            invocation.environment = request.environment
            invocation.workingDirectory = request.workingDirectory
            command = try render(invocation, shell: shell).command
        case .rawShell(let family, let raw, let reason):
            try reserveText(raw)
            guard request.environment.isEmpty, request.workingDirectory == nil,
                  !raw.contains("\0") else { throw invalid() }
            // Legacy execution must not trigger environment detection recursively.
            if case .compatibility = reason { command = raw }
            else {
                switch family {
                case .posix: command = "sh -c \(posixQuote(raw))"
                case .powershell: command = try powerShellCommand(raw, shell: shell)
                case .cmd: command = "cmd.exe /d /v:off /c \(raw)"
                case .unknown: throw unsupported()
                }
            }
        }
        guard !command.isEmpty, command.utf8.count <= 65_536 else { throw invalid() }
        return RenderedRemoteProcess(command: command, stdin: input, closesStdin: closesInput)
    }

    static func posixQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func powerShellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Windows CRT argument rules. Used inside the encoded PowerShell launcher.
    static func windowsArgument(_ text: String) -> String {
        var result = "\""
        var slashes = ""
        for character in text {
            if character == "\\" { slashes.append(character); continue }
            if character == "\"" { result += slashes + slashes + "\\\"" }
            else { result += slashes + String(character) }
            slashes = ""
        }
        return result + slashes + slashes + "\""
    }

    /// cmd expands percent variables even inside quotes. Refuse values that
    /// cannot be represented safely; callers can use a detected PowerShell host.
    static func cmdArgument(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { [34, 37, 33, 13, 10, 0].contains($0.value) }) else { throw unsupported() }
        return "\"\(text)\""
    }

    private static func powerShellCommand(_ script: String, shell: RemoteShellProfile) throws -> String {
        let encoded = Data(script.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
        return try powerShellExecutable(shell) + " -NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded.base64EncodedString()
    }

    private static func powerShellExecutable(_ shell: RemoteShellProfile) throws -> String {
        let executable = shell.executableName ?? "powershell.exe"
        guard ["powershell", "powershell.exe", "pwsh", "pwsh.exe"].contains(executable.lowercased()) else { throw unsupported() }
        return executable
    }

    private static func validEnvironmentName(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard let first = bytes.first, first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return bytes.allSatisfy { $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }

    private static func invalid() -> RemoteProcessFailure { .init(reason: .invalidRequest, dispatch: .notDispatched) }
    private static func unsupported() -> RemoteProcessFailure { .init(reason: .unsupportedShell, dispatch: .notDispatched) }
}
