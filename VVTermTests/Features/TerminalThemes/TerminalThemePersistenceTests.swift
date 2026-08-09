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
        XCTAssertEqual(
            manager.appearanceSnapshot(for: .dark).activeTheme.name,
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

    func testAppearanceSnapshotResolvesBothThemesFromOnePreferenceSnapshot() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let darkTheme = TerminalTheme(
            name: "Test Dark",
            content: "background = #102030\nforeground = #A0B0C0\ncursor-color = #D0E0F0\n"
        )
        let lightTheme = TerminalTheme(
            name: "Test Light",
            content: "background = #F1F2F3\nforeground = #112233\ncursor-text = #445566\n"
        )
        defaults.set(
            try JSONEncoder().encode([darkTheme, lightTheme]),
            forKey: CloudKitSyncConstants.terminalCustomThemesStorageKey
        )
        defaults.set(darkTheme.name, forKey: CloudKitSyncConstants.terminalThemeNameKey)
        defaults.set(lightTheme.name, forKey: CloudKitSyncConstants.terminalThemeNameLightKey)
        defaults.set(true, forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey)

        let manager = TerminalThemeManager(
            defaults: defaults,
            fileStore: TerminalThemeFileStore(directoryURL: temporaryDirectory),
            startsSynchronization: false
        )
        let snapshot = manager.appearanceSnapshot(for: .light)

        XCTAssertEqual(snapshot.activeTheme.name, lightTheme.name)
        XCTAssertEqual(snapshot.lightTheme.palette.backgroundHex, "#F1F2F3")
        XCTAssertEqual(snapshot.lightTheme.palette.foregroundHex, "#112233")
        XCTAssertEqual(snapshot.lightTheme.palette.cursorHex, "#112233")
        XCTAssertEqual(snapshot.lightTheme.palette.cursorTextHex, "#445566")
        XCTAssertEqual(snapshot.darkTheme.palette.backgroundHex, "#102030")
        XCTAssertEqual(snapshot.darkTheme.palette.foregroundHex, "#A0B0C0")
        XCTAssertEqual(snapshot.darkTheme.palette.cursorHex, "#D0E0F0")
        XCTAssertEqual(snapshot.darkTheme.palette.cursorTextHex, "#102030")
    }

    func testAppearanceActivationIsOrderedAndOwnsLegacyBackgroundCache() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let darkTheme = TerminalTheme(
            name: "Ordered Dark",
            content: "background = #010203\nforeground = #FFFFFF\n"
        )
        let lightTheme = TerminalTheme(
            name: "Ordered Light",
            content: "background = #FDFCFB\nforeground = #000000\n"
        )
        defaults.set(
            try JSONEncoder().encode([darkTheme, lightTheme]),
            forKey: CloudKitSyncConstants.terminalCustomThemesStorageKey
        )
        defaults.set(darkTheme.name, forKey: CloudKitSyncConstants.terminalThemeNameKey)
        defaults.set(lightTheme.name, forKey: CloudKitSyncConstants.terminalThemeNameLightKey)
        defaults.set(true, forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey)

        let manager = TerminalThemeManager(
            defaults: defaults,
            fileStore: TerminalThemeFileStore(directoryURL: temporaryDirectory),
            startsSynchronization: false
        )

        let lightSnapshot = manager.activateAppearance(.light)
        XCTAssertEqual(manager.activeAppearanceSnapshot, lightSnapshot)
        XCTAssertEqual(defaults.string(forKey: "terminalBackgroundColor"), "#FDFCFB")

        let darkSnapshot = manager.activateAppearance(.dark)
        XCTAssertEqual(manager.activeAppearanceSnapshot, darkSnapshot)
        XCTAssertEqual(defaults.string(forKey: "terminalBackgroundColor"), "#010203")
    }
}
