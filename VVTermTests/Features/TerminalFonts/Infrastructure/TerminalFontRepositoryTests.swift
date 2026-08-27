import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalFontRepositoryTests {
    @Test
    func importsRegistersAndPersistsAppOwnedFont() throws {
        let suiteName = "TerminalFontRepositoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let root = try testDirectory()
        let repository = LocalTerminalFontRepository(
            rootDirectoryURL: root,
            defaults: defaults
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let imported = try repository.importFont(
            from: try bundledFontURL(),
            now: Date(timeIntervalSince1970: 100)
        )
        defer { repository.removeFile(for: imported) }

        #expect(!imported.familyNames.isEmpty)
        #expect(repository.existingFileURL(for: imported) != nil)

        try repository.saveFonts([imported])
        #expect(try repository.loadFonts() == [imported])

        let preference = TerminalFontPreference(
            primaryFamily: imported.displayName,
            cjkFamily: nil,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        repository.savePreference(preference)
        #expect(repository.loadPreference() == preference)
    }

    private func bundledFontURL() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.lastPathComponent != "VVTermTests" {
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else {
                throw TerminalFontValidationError.fileUnavailable
            }
            directory = parent
        }
        return directory.deletingLastPathComponent()
            .appendingPathComponent("VVTerm/Resources/Fonts/HackNerdFont-Regular.ttf")
    }

    private func testDirectory() throws -> URL {
        let caches = try #require(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        return caches
            .appendingPathComponent("VVTermTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
