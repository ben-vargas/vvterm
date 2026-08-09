import CloudKit
import Foundation
import Testing
@testable import VVTerm

struct ServerCloudKitRecordCodecTests {
    @Test
    func serverRecordPreservesIdentityAndRoundTripsFields() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let server = makeServer()

        let record = ServerCloudKitRecordCodec.record(for: server, in: zoneID)

        #expect(record.recordType == "Server")
        #expect(record.recordID.recordName == server.id.uuidString)
        #expect(record.recordID.zoneID == zoneID)
        var expected = server
        expected.updatedAt = try #require(record["updatedAt"] as? Date)
        #expect(ServerCloudKitRecordCodec.server(from: record) == expected)
    }

    @Test
    func workspaceRecordPreservesIdentityAndRoundTripsFields() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let workspace = makeWorkspace()

        let record = WorkspaceCloudKitRecordCodec.record(for: workspace, in: zoneID)

        #expect(record.recordType == "Workspace")
        #expect(record.recordID.recordName == workspace.id.uuidString)
        #expect(record.recordID.zoneID == zoneID)
        var expected = workspace
        expected.updatedAt = try #require(record["updatedAt"] as? Date)
        #expect(WorkspaceCloudKitRecordCodec.workspace(from: record) == expected)
    }

    @Test
    func domainCodableShapeRoundTripsWithoutLosingValues() throws {
        let server = makeServer()
        let workspace = makeWorkspace()

        let serverData = try JSONEncoder().encode(server)
        let workspaceData = try JSONEncoder().encode(workspace)

        #expect(try JSONDecoder().decode(Server.self, from: serverData) == server)
        #expect(try JSONDecoder().decode(Workspace.self, from: workspaceData) == workspace)
    }

    private func makeServer() -> Server {
        Server(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            workspaceId: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            environment: ServerEnvironment(
                id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                name: "QA",
                shortName: "QA",
                colorHex: "#123456"
            ),
            name: "Round Trip",
            host: "roundtrip.example.test",
            port: 2_222,
            eternalTerminalPort: 2_023,
            username: "tester",
            connectionMode: .cloudflare,
            authMethod: .sshKeyWithPassphrase,
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.example.test",
            cloudflareAppDomainOverride: "app.example.test",
            tags: ["one", "two"],
            notes: "Notes",
            lastConnected: Date(timeIntervalSinceReferenceDate: 1_500),
            isFavorite: true,
            requiresBiometricUnlock: true,
            tmuxEnabledOverride: false,
            tmuxStartupBehaviorOverride: .skipTmux,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
    }

    private func makeWorkspace() -> Workspace {
        let environment = ServerEnvironment(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "Preview",
            shortName: "Pre",
            colorHex: "#654321"
        )
        return Workspace(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "Round Trip",
            colorHex: "#ABCDEF",
            icon: "terminal",
            order: 7,
            environments: [environment],
            lastSelectedEnvironmentId: environment.id,
            lastSelectedServerId: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
    }
}
