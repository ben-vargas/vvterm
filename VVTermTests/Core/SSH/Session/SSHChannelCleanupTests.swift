import Foundation
import Testing
@testable import VVTerm

struct SSHChannelCleanupTests {
    @Test(arguments: [Int32(0), Int32(LIBSSH2_ERROR_SFTP_PROTOCOL)])
    func nonblockingCleanupRetriesAndPreservesTheFinalStatus(_ finalStatus: Int32) async {
        let session = SSHSession(
            config: SSHSessionConfig(
                host: "test.invalid",
                port: 22,
                username: "test",
                connectionMode: .standard,
                authMethod: .password,
                credentials: ServerCredentials(serverId: UUID())
            ),
            hostKeyVerifier: TestingSSHHostKeyVerifier()
        )

        let result = await session.completeChannelCleanupCallForTesting(
            results: [
                Int32(LIBSSH2_ERROR_EAGAIN),
                Int32(LIBSSH2_ERROR_EAGAIN),
                finalStatus,
            ]
        )

        #expect(result.result == finalStatus)
        #expect(result.callCount == 3)
    }
}
