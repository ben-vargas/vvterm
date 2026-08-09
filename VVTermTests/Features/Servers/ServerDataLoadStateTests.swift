import Foundation
import XCTest
@testable import VVTerm

final class ServerDataLoadStateTests: XCTestCase {
    func testFailureRemainsVisibleAfterLoadFinishes() {
        var state = ServerDataLoadState()
        let operationID = state.start()

        XCTAssertTrue(state.fail(operationID: operationID, message: "CloudKit unavailable"))

        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.errorMessage, "CloudKit unavailable")
    }

    func testStaleCompletionCannotFinishNewLoad() {
        var state = ServerDataLoadState()
        let firstOperationID = state.start()
        let secondOperationID = state.start()

        XCTAssertFalse(state.finish(operationID: firstOperationID))
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)

        XCTAssertTrue(state.finish(operationID: secondOperationID))
        XCTAssertFalse(state.isLoading)
    }

    func testNewLoadClearsPreviousFailure() {
        var state = ServerDataLoadState()
        let failedOperationID = state.start()
        state.fail(operationID: failedOperationID, message: "Failed")

        _ = state.start()

        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }
}
