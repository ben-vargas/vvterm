import Foundation
import Testing
@testable import VVTerm

struct AppServerConnectionTestPlanTests {
    @Test
    func standardUsesOnlyTheSSHProbe() {
        #expect(ServerConnectionTestPlan(server: makeServer(mode: .standard)) == .sshOnly)
    }

    @Test
    func tailscaleUsesOnlyTheSSHProbe() {
        #expect(ServerConnectionTestPlan(server: makeServer(mode: .tailscale)) == .sshOnly)
    }

    @Test
    func cloudflareUsesOnlyTheSSHProbe() {
        #expect(ServerConnectionTestPlan(server: makeServer(mode: .cloudflare)) == .sshOnly)
    }

    @Test
    func moshUsesTheBoundedBootstrapPortRange() {
        #expect(
            ServerConnectionTestPlan(server: makeServer(mode: .mosh))
                == .mosh(portRange: 60_001...61_000)
        )
    }

    @Test
    func eternalTerminalUsesItsConfiguredPortAndBoundsInvalidValues() {
        var server = makeServer(mode: .eternalTerminal)
        server.eternalTerminalPort = 22_022
        #expect(ServerConnectionTestPlan(server: server) == .eternalTerminal(port: 22_022))

        server.eternalTerminalPort = Int.max
        #expect(ServerConnectionTestPlan(server: server) == .eternalTerminal(port: 2_022))

        server.eternalTerminalPort = 0
        #expect(ServerConnectionTestPlan(server: server) == .eternalTerminal(port: 2_022))
    }

    @Test
    func hostKeyFailureRequiresApprovalForTheCurrentEndpoint() {
        let server = makeServer(mode: .standard)

        #expect(
            ServerConnectionApprovalPolicy.requirement(
                for: SSHError.hostKeyApprovalRequired,
                server: server
            ) == .hostKey(host: server.host, port: server.port)
        )
    }

    @Test
    func changedCredentialBindingRequiresCredentialEndpointApproval() {
        let server = makeServer(mode: .cloudflare)

        #expect(
            ServerConnectionApprovalPolicy.requirement(
                for: ServerCredentialAccessError.approvalRequired,
                server: server
            ) == .credentialEndpoint
        )
    }

    @Test
    func unrelatedFailureDoesNotRequestApproval() {
        #expect(
            ServerConnectionApprovalPolicy.requirement(
                for: SSHError.authenticationFailed,
                server: makeServer(mode: .standard)
            ) == nil
        )
    }

    private func makeServer(mode: SSHConnectionMode) -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            port: 2222,
            username: "root",
            connectionMode: mode
        )
    }
}
