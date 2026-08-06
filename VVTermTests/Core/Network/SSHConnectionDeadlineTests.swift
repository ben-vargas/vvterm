#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct SSHConnectionDeadlineTests {
    @Test
    func blockedHandshakeIsAbortedAtTheHardDeadline() async throws {
        let listener = try LoopbackListener()
        let client = SSHClient(connectTimeout: .milliseconds(100))
        let server = Server(
            workspaceId: UUID(),
            name: "Blocked handshake",
            host: "127.0.0.1",
            port: listener.port,
            username: "test",
            authMethod: .password
        )
        let credentials = ServerCredentials(serverId: server.id, password: "unused")
        let startedAt = ContinuousClock.now

        do {
            _ = try await client.connect(to: server, credentials: credentials)
            Issue.record("Expected the blocked SSH handshake to time out")
        } catch let error as SSHError {
            guard case .timeout = error else {
                Issue.record("Expected SSHError.timeout, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected SSHError.timeout, received \(error)")
        }

        #expect(startedAt.duration(to: .now) < .seconds(2))
        listener.close()
        await client.disconnect()
    }
}
#endif
