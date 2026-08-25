import Foundation

/// A user-provided command. Unix hosts run it with `/bin/sh`; Windows hosts use
/// the detected PowerShell or cmd.exe shell.
nonisolated struct RemoteShellStartupAction: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case empty
        case containsUnsupportedControlCharacters
        case tooLong
    }

    // Leave room for the psmux launch script, environment prefix, UTF-16LE
    // encoding, and PowerShell arguments within Windows' process limit.
    static let maximumCommandByteCount = 9_000

    let command: String

    init(command: String) throws {
        let normalized = command
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ValidationError.empty
        }
        guard normalized.utf8.count <= Self.maximumCommandByteCount else {
            throw ValidationError.tooLong
        }
        let allowedControlCharacters = CharacterSet(charactersIn: "\t\n")
        let unsupportedControlCharacters = CharacterSet.controlCharacters
            .subtracting(allowedControlCharacters)
        guard normalized.rangeOfCharacter(from: unsupportedControlCharacters) == nil else {
            throw ValidationError.containsUnsupportedControlCharacters
        }
        self.command = normalized
    }
}
