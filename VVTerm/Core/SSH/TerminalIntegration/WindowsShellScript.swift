import Foundation

/// Transfers the script as a file, not as part of Windows OpenSSH's PTY command.
nonisolated struct WindowsShellScript: Sendable {
    // Reserve room for sshd's default shell path and ConPTY launcher arguments.
    static let directCommandLimit = 6_000

    let remotePath: String
    let contents: Data
    let launcher: String

    static func needsTransfer(command: String?, environment: RemoteEnvironment) -> Bool {
        guard environment.platform == .windows, environment.shellProfile.family == .powershell,
              case .exec(let invocation) = RemoteTerminalBootstrap.launchPlan(
                startupCommand: command, environment: environment
              ) else { return false }
        return invocation.utf16.count > directCommandLimit
    }

    init(command: String, homeDirectory: String, id: UUID = UUID()) throws {
        guard let directory = RemoteTerminalBootstrap.normalizedWindowsPath(from: homeDirectory),
              !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SFTPTransportError.invalidEntryName
        }
        remotePath = homeDirectory + "/.vvterm-start-" + id.uuidString + ".ps1"
        let path = directory + "\\.vvterm-start-" + id.uuidString + ".ps1"
        contents = Data(RemoteTerminalBootstrap.prefixedPowerShellScript(for: command).utf8)
        launcher = Self.launcher(path: path)
    }

    static func launcher(path: String) -> String {
        let quoted = RemoteTerminalBootstrap.powerShellQuoted(path)
        // Read and delete before invoking. A long-running terminal does not
        // keep a startup file, and a rejected request can safely remove it.
        return """
        $vvtermScriptPath = \(quoted)
        try {
          $vvtermScript = [IO.File]::ReadAllText($vvtermScriptPath, [Text.Encoding]::UTF8)
          [IO.File]::Delete($vvtermScriptPath)
        } catch { throw }
        & ([ScriptBlock]::Create($vvtermScript))
        """
    }
}
