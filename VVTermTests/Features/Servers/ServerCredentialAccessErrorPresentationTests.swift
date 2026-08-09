import Foundation
import Testing
@testable import VVTerm

struct ServerCredentialAccessErrorPresentationTests {
    @Test
    func approvalRequiredKeepsItsExactLocalizedDescriptionAPI() {
        let error = ServerCredentialAccessError.approvalRequired
        let expected = String(
            localized: "Stored credentials are linked to another server endpoint. Approve this endpoint before using them."
        )

        #expect(error.errorDescription == expected)
        #expect(error.localizedDescription == expected)
    }
}
