import Foundation

/// No shell request was sent. A retry cannot repeat the startup action.
nonisolated struct SSHShellPreparationError: LocalizedError, Sendable {
    let underlying: any Error

    var errorDescription: String? { underlying.localizedDescription }
}
