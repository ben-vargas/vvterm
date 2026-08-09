import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerCredentialBindingTests {
    @Test
    func metadataOnlyChangesKeepCredentialBinding() {
        let original = makeServer()
        var updated = original
        updated.name = "Renamed"
        updated.notes = "Metadata only"
        updated.tags = ["new-tag"]
        updated.workspaceId = UUID()
        updated.environment = .development

        #expect(ServerCredentialBinding(server: original) == ServerCredentialBinding(server: updated))
    }

    @Test(arguments: EndpointChange.allCases)
    func endpointChangesRequireApproval(change: EndpointChange) {
        let original = makeServer(connectionMode: .cloudflare)
        var updated = original
        change.apply(to: &updated)

        let status = ServerCredentialBindingStatus.resolve(
            storedBinding: ServerCredentialBinding(server: original),
            currentBinding: ServerCredentialBinding(server: updated),
            hasStoredCredentials: true
        )

        #expect(status == .approvalRequired)
    }

    @Test
    func equivalentNetworkNamesKeepCredentialBinding() {
        let original = makeServer(host: " EXAMPLE.COM. ", connectionMode: .cloudflare)
        var updated = original
        updated.host = "example.com"
        updated.cloudflareTeamDomainOverride = " TEAM.EXAMPLE.COM. "

        var normalizedOriginal = original
        normalizedOriginal.cloudflareTeamDomainOverride = "team.example.com"

        #expect(
            ServerCredentialBinding(server: normalizedOriginal)
                == ServerCredentialBinding(server: updated)
        )
    }

    @Test
    func missingBindingRequiresApprovalForExistingCredentials() {
        let status = ServerCredentialBindingStatus.resolve(
            storedBinding: nil,
            currentBinding: ServerCredentialBinding(server: makeServer()),
            hasStoredCredentials: true
        )

        #expect(status == .approvalRequired)
    }

    @Test
    func missingCredentialsNeedNoApproval() {
        let status = ServerCredentialBindingStatus.resolve(
            storedBinding: nil,
            currentBinding: ServerCredentialBinding(server: makeServer()),
            hasStoredCredentials: false
        )

        #expect(status == .noCredentials)
    }

    @Test
    func inMemoryCredentialsRequireTheirApprovedEndpoint() throws {
        let original = makeServer()
        let credentials = ServerCredentials(
            serverId: original.id,
            credentialBinding: ServerCredentialBinding(server: original),
            password: "secret"
        )

        try credentials.requireAuthorization(for: original)

        var changed = original
        changed.host = "other.example.com"

        #expect(!credentials.isAuthorized(for: changed))
        #expect(throws: ServerCredentialAccessError.approvalRequired) {
            try credentials.requireAuthorization(for: changed)
        }
    }

    @Test
    func unboundInMemoryCredentialsAreRejected() {
        let server = makeServer()
        let credentials = ServerCredentials(serverId: server.id, password: "secret")

        #expect(!credentials.isAuthorized(for: server))
    }

    enum EndpointChange: CaseIterable {
        case host
        case port
        case eternalTerminalPort
        case username
        case connectionMode
        case authMethod
        case cloudflareAccessMode
        case cloudflareTeamDomain
        case cloudflareAppDomain

        func apply(to server: inout Server) {
            switch self {
            case .host:
                server.host = "other.example.com"
            case .port:
                server.port = 2222
            case .eternalTerminalPort:
                server.connectionMode = .eternalTerminal
                server.eternalTerminalPort = 2023
            case .username:
                server.username = "other-user"
            case .connectionMode:
                server.connectionMode = .standard
            case .authMethod:
                server.authMethod = .sshKey
            case .cloudflareAccessMode:
                server.cloudflareAccessMode = .serviceToken
            case .cloudflareTeamDomain:
                server.cloudflareTeamDomainOverride = "other.cloudflareaccess.com"
            case .cloudflareAppDomain:
                server.cloudflareAppDomainOverride = "other.example.com"
            }
        }
    }

    private func makeServer(
        host: String = "example.com",
        connectionMode: SSHConnectionMode = .eternalTerminal
    ) -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: host,
            port: 22,
            eternalTerminalPort: 2022,
            username: "root",
            connectionMode: connectionMode,
            authMethod: .password,
            cloudflareAccessMode: connectionMode == .cloudflare ? .oauth : nil,
            cloudflareTeamDomainOverride: connectionMode == .cloudflare
                ? "team.cloudflareaccess.com"
                : nil,
            cloudflareAppDomainOverride: connectionMode == .cloudflare
                ? "app.example.com"
                : nil
        )
    }
}
