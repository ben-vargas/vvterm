import XCTest
@testable import VVTerm

final class TmuxDomainTests: XCTestCase {
    func testStartupBehaviorCasesPreserveRawValueOrder() {
        XCTAssertEqual(
            RemoteSessionStartupBehavior.allCases.map(\.rawValue),
            ["createManaged", "ask", "plainShell"]
        )
    }

    func testStatusTmuxIndicationRules() {
        XCTAssertTrue(RemoteSessionStatus.foreground.indicatesPersistentSession)
        XCTAssertTrue(RemoteSessionStatus.background.indicatesPersistentSession)
        XCTAssertTrue(RemoteSessionStatus.unknown.indicatesPersistentSession)
        XCTAssertFalse(RemoteSessionStatus.off.indicatesPersistentSession)
        XCTAssertFalse(RemoteSessionStatus.missing.indicatesPersistentSession)
        XCTAssertFalse(RemoteSessionStatus.installing.indicatesPersistentSession)
    }
}
