import Foundation

nonisolated struct SSHCommandExitError: LocalizedError, Sendable {
    let exitStatus: Int32

    var errorDescription: String? {
        String(format: String(localized: "Remote command failed (exit code %d)."), exitStatus)
    }
}
