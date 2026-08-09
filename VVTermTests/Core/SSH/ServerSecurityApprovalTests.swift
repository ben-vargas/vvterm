import XCTest
@testable import VVTerm

final class ServerSecurityApprovalTests: XCTestCase {
    func testDetectsCredentialEndpointApproval() {
        let server = makeServer()

        XCTAssertEqual(
            ServerSecurityApprovalRequest.detect(
                ServerCredentialAccessError.approvalRequired,
                server: server
            ),
            .credentialEndpoint(serverID: server.id)
        )
    }

    func testDetectsPendingHostKeyApproval() throws {
        let suiteName = "ServerSecurityApprovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let knownHosts = KnownHostsManager(
            defaults: defaults,
            storageKey: "known-hosts"
        )
        let server = makeServer()
        guard case .approvalRequired(let challenge) = knownHosts.evaluate(
            host: server.host,
            port: server.port,
            fingerprint: "SHA256:test",
            keyType: 1,
            keyTypeName: "ssh-ed25519"
        ) else {
            return XCTFail("Expected an approval challenge")
        }

        XCTAssertEqual(
            ServerSecurityApprovalRequest.detect(
                SSHError.hostKeyApprovalRequired,
                server: server,
                knownHosts: knownHosts
            ),
            .hostKey(challenge)
        )
    }

    func testDoesNotInventMissingOrExpiredHostKeyChallenge() throws {
        let suiteName = "ServerSecurityApprovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let knownHosts = KnownHostsManager(
            defaults: defaults,
            storageKey: "known-hosts"
        )

        XCTAssertNil(
            ServerSecurityApprovalRequest.detect(
                SSHError.hostKeyApprovalRequired,
                server: makeServer(),
                knownHosts: knownHosts
            )
        )
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            port: 22,
            username: "root",
            authMethod: .password
        )
    }
}
