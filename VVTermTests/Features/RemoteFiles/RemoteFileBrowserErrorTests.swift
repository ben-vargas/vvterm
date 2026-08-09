import XCTest
@testable import VVTerm

final class RemoteFileBrowserErrorTests: XCTestCase {
    func testCredentialApprovalKeepsTypedError() {
        XCTAssertEqual(
            RemoteFileBrowserError.map(
                ServerCredentialAccessError.approvalRequired
            ),
            .credentialApprovalRequired
        )
    }

    func testHostKeyApprovalKeepsTypedError() {
        XCTAssertEqual(
            RemoteFileBrowserError.map(SSHError.hostKeyApprovalRequired),
            .hostKeyApprovalRequired
        )
    }

    func testApprovalErrorsDoNotBecomeMissingCredentials() {
        XCTAssertNotEqual(
            RemoteFileBrowserError.credentialApprovalRequired.errorDescription,
            "No credentials found"
        )
        XCTAssertNotEqual(
            RemoteFileBrowserError.hostKeyApprovalRequired.errorDescription,
            "No credentials found"
        )
    }

    func testMappingAlreadyTypedApprovalDoesNotEraseItsType() {
        XCTAssertEqual(
            RemoteFileBrowserError.map(
                RemoteFileBrowserError.credentialApprovalRequired
            ),
            .credentialApprovalRequired
        )
        XCTAssertEqual(
            RemoteFileBrowserError.map(
                RemoteFileBrowserError.hostKeyApprovalRequired
            ),
            .hostKeyApprovalRequired
        )
    }
}
