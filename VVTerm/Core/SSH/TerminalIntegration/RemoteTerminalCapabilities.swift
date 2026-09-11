import Foundation

/// Derived from the actual output path, never from saved transport preferences.
nonisolated struct RemoteTerminalCapabilities: Equatable, Sendable {
    let transport: ShellTransport
    let resolvedTerminalType: RemoteTerminalType

    var terminalType: RemoteTerminalType {
        transport == .mosh ? .xterm256Color : resolvedTerminalType
    }

    var supportsTrueColor: Bool { true }
    var terminalProgram: String? { transport == .mosh ? nil : RemoteTerminalBootstrap.termProgram }
    var supportsKittyGraphics: Bool { transport != .mosh }
    var supportsDesktopNotifications: Bool { transport != .mosh }
    var supportsProgress: Bool { transport != .mosh }
    var needsSnacksSSHCompatibility: Bool { transport == .eternalTerminal }

    static let managedEnvironmentNames = ["COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "SNACKS_SSH"]

    var removedEnvironmentNames: [String] {
        var names: [String] = []
        if terminalProgram == nil { names += ["TERM_PROGRAM", "TERM_PROGRAM_VERSION"] }
        if !needsSnacksSSHCompatibility { names.append("SNACKS_SSH") }
        return names
    }
}
