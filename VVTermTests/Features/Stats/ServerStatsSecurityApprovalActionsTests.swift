import XCTest
@testable import VVTerm

final class ServerStatsSecurityApprovalActionsTests: XCTestCase {
    @MainActor
    func testApproveForwardsTheRequestAndServerToInjectedEffect() async {
        let server = makeServer()
        let request = ServerSecurityApprovalRequest.credentialEndpoint(serverID: server.id)
        var receivedRequest: ServerSecurityApprovalRequest?
        var receivedServer: Server?
        let actions = ServerStatsSecurityApprovalActions(
            approve: { request, server in
                receivedRequest = request
                receivedServer = server
                return .approved
            },
            reject: { _ in }
        )

        let outcome = await actions.approve(request, server)

        XCTAssertEqual(outcome, .approved)
        XCTAssertEqual(receivedRequest, request)
        XCTAssertEqual(receivedServer, server)
    }

    @MainActor
    func testRejectUsesOnlyItsInjectedEffect() {
        let serverID = UUID()
        let request = ServerSecurityApprovalRequest.credentialEndpoint(serverID: serverID)
        var firstRejections: [ServerSecurityApprovalRequest] = []
        var secondRejections: [ServerSecurityApprovalRequest] = []
        let first = ServerStatsSecurityApprovalActions(
            approve: { _, _ in .approved },
            reject: { firstRejections.append($0) }
        )
        let second = ServerStatsSecurityApprovalActions(
            approve: { _, _ in .failed(.unavailable) },
            reject: { secondRejections.append($0) }
        )

        first.reject(request)

        XCTAssertEqual(firstRejections, [request])
        XCTAssertTrue(secondRejections.isEmpty)
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "stats-actions-test",
            host: "stats.example.test",
            username: "tester"
        )
    }
}
