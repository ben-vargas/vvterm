import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class RemoteSessionPresentationTests: XCTestCase {
    func testRemoteSessionPromptCopyExistsInEveryLocalization() throws {
        let keys = [
            "Choose %@ session",
            "No %@ sessions found",
            "Create a new session, or continue without a remote session.",
            "Continue without a remote session",
            "Open Installation Guide",
            "Use a normal shell",
            "Start a normal shell without remote session persistence.",
            "Installing %@",
            "Install %@?",
            "The remote session is still running on the server."
        ]

        for localization in Bundle.main.localizations.sorted() where localization != "Base" {
            let url = try XCTUnwrap(
                Bundle.main.url(
                    forResource: "Localizable",
                    withExtension: "strings",
                    subdirectory: nil,
                    localization: localization
                ),
                "Missing Localizable.strings for \(localization)"
            )
            let data = try Data(contentsOf: url)
            let catalog = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            )

            for key in keys {
                XCTAssertNotNil(catalog[key], "Missing \(key) in \(localization)")
            }
        }
    }

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
