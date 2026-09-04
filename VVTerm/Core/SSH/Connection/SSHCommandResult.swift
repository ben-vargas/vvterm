import Foundation

nonisolated struct SSHCommandResult: Sendable {
    let output: String
    let exitStatus: Int32

    func requireSuccess() throws {
        guard exitStatus == 0 else { throw SSHCommandExitError(exitStatus: exitStatus) }
    }
}
