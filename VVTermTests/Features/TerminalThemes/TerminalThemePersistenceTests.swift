import XCTest
@testable import VVTerm

@MainActor
final class TerminalThemePersistenceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VVTermThemeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testInvalidThemeSurvivesLoadingAndDoesNotDeleteItsFileOrSelection() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = "background = #000000\nforeground = #ffffff\ncommand = whoami\n"
        let theme = TerminalTheme(name: "Legacy Theme", content: original)
        defaults.set(
            try JSONEncoder().encode([theme]),
            forKey: CloudKitSyncConstants.terminalCustomThemesStorageKey
        )
        defaults.set(theme.name, forKey: CloudKitSyncConstants.terminalThemeNameKey)

        let store = TerminalThemeFileStore(directoryURL: temporaryDirectory)
        let fileURL = try XCTUnwrap(store.fileURL(for: theme.name))
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let manager = TerminalThemeManager(
            defaults: defaults,
            fileStore: store,
            startsSynchronization: false
        )

        XCTAssertEqual(manager.customThemes, [theme])
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), original)
        XCTAssertEqual(
            defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameKey),
            theme.name
        )
        XCTAssertEqual(
            manager.applicationThemeName(preferred: theme.name, fallback: "Aizen Dark"),
            "Aizen Dark"
        )
    }

    func testValidThemeWriteDoesNotDeleteUnrelatedThemeFiles() throws {
        let store = TerminalThemeFileStore(directoryURL: temporaryDirectory)
        let unrelatedURL = temporaryDirectory.appendingPathComponent("Existing Legacy Theme")
        let original = "legacy content"
        try original.write(to: unrelatedURL, atomically: true, encoding: .utf8)

        let validTheme = TerminalTheme(
            name: "Valid Theme",
            content: "background = #000000\nforeground = #ffffff\n"
        )
        try store.synchronize([validTheme])

        XCTAssertEqual(try String(contentsOf: unrelatedURL, encoding: .utf8), original)
        let validURL = try XCTUnwrap(store.fileURL(for: validTheme.name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: validURL.path))
    }

    func testFailedValidationDoesNotReplaceExistingThemeFile() throws {
        let store = TerminalThemeFileStore(directoryURL: temporaryDirectory)
        let theme = TerminalTheme(
            name: "Needs Repair",
            content: "background = #000000\nforeground = #ffffff\ncommand = whoami\n"
        )
        let fileURL = try XCTUnwrap(store.fileURL(for: theme.name))
        let existing = "background = #112233\nforeground = #ddeeff\n"
        try existing.write(to: fileURL, atomically: true, encoding: .utf8)

        try store.synchronize([theme])

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), existing)
    }

    func testInvalidRemoteThemeDoesNotReplaceValidLocalTheme() {
        let id = UUID()
        let local = TerminalTheme(
            id: id,
            name: "Safe Theme",
            content: "background = #000000\nforeground = #ffffff\n",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let invalidRemote = TerminalTheme(
            id: id,
            name: "Safe Theme",
            content: "background = #000000\nforeground = #ffffff\ncommand = whoami\n",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(TerminalThemeMergePolicy.merge(local: [local], remote: [invalidRemote]), [local])
    }

    func testExplicitDeletionRemovesThemeFile() throws {
        let store = TerminalThemeFileStore(directoryURL: temporaryDirectory)
        var theme = TerminalTheme(
            name: "Delete Me",
            content: "background = #000000\nforeground = #ffffff\n"
        )
        try store.synchronize([theme])
        let fileURL = try XCTUnwrap(store.fileURL(for: theme.name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        theme.deletedAt = Date()
        try store.synchronize([theme])

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
