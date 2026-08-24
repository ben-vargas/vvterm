import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class RemoteSessionPresentationTests: XCTestCase {
    func testStartupBehaviorPresentationMatchesExistingLocalizedCopy() {
        XCTAssertEqual(
            RemoteSessionStartupBehavior.createManaged.displayName,
            String(localized: "Create VVTerm session")
        )
        XCTAssertEqual(
            RemoteSessionStartupBehavior.ask.displayName,
            String(localized: "Ask every time")
        )
        XCTAssertEqual(
            RemoteSessionStartupBehavior.plainShell.displayName,
            String(localized: "Use a normal shell")
        )

        XCTAssertEqual(
            RemoteSessionStartupBehavior.createManaged.descriptionText,
            String(localized: "Create or reconnect to a VVTerm-managed session.")
        )
        XCTAssertEqual(
            RemoteSessionStartupBehavior.ask.descriptionText,
            String(localized: "Ask which session to use for each new tab or split.")
        )
        XCTAssertEqual(
            RemoteSessionStartupBehavior.plainShell.descriptionText,
            String(localized: "Start a normal shell without remote session persistence.")
        )
    }

    func testStatusPresentationMatchesExistingCopy() {
        let expected: [(RemoteSessionStatus, shortLabel: String, displayName: String)] = [
            (.foreground, "tmux", "Foreground"),
            (.background, "tmux", "Background"),
            (.off, "off", "Off"),
            (.missing, "tmux missing", "Unavailable"),
            (.installing, "tmux install", "Installing"),
            (.unknown, "tmux", "Unknown")
        ]

        for (status, shortLabel, displayName) in expected {
            XCTAssertEqual(status.shortLabel(backendName: "tmux"), shortLabel)
            XCTAssertEqual(status.displayName, displayName)
        }
    }
}
