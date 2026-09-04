import Testing
@testable import VVTerm

struct SSHCommandResultTests {
    @Test(arguments: [Int32(0), 1, 255, -1])
    func onlyZeroExitStatusIsSuccessful(_ status: Int32) throws {
        let result = SSHCommandResult(output: "diagnostic output", exitStatus: status)
        if status == 0 {
            try result.requireSuccess()
        } else {
            #expect(throws: SSHCommandExitError.self) { try result.requireSuccess() }
        }
    }
}
