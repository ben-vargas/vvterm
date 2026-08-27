import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class TerminalFontRepositoryStub: TerminalFontRepository {
    var fonts: [TerminalFont]
    var preference: TerminalFontPreference
    var imported: TerminalFont?
    private(set) var removedFontIDs: [TerminalFont.ID] = []

    init(
        fonts: [TerminalFont] = [],
        preference: TerminalFontPreference = .defaultValue
    ) {
        self.fonts = fonts
        self.preference = preference
    }

    func loadFonts() throws -> [TerminalFont] { fonts }
    func saveFonts(_ fonts: [TerminalFont]) throws { self.fonts = fonts }
    func loadPreference() -> TerminalFontPreference { preference }
    func savePreference(_ preference: TerminalFontPreference) { self.preference = preference }

    func importFont(from sourceURL: URL, now: Date) throws -> TerminalFont {
        try #require(imported)
    }

    func installRemoteAsset(from sourceURL: URL, for font: TerminalFont) throws {}

    func registerAvailableFonts(
        _ fonts: [TerminalFont]
    ) -> [TerminalFont.ID: [TerminalFontFamily]] {
        Dictionary(uniqueKeysWithValues: fonts.filter { !$0.isDeleted }.map { font in
            (
                font.id,
                font.familyNames.map {
                    TerminalFontFamily(name: $0, source: .custom)
                }
            )
        })
    }

    func removeFile(for font: TerminalFont) {
        removedFontIDs.append(font.id)
    }

    func existingFileURL(for font: TerminalFont) -> URL? {
        font.isDeleted ? nil : URL(fileURLWithPath: "/font-\(font.id).ttf")
    }
}

@MainActor
private final class TerminalFontCloudStub: TerminalFontCloudClient {
    var fonts: [TerminalFont] = []
    var preference: TerminalFontPreference?

    func fetchTerminalFonts() async throws -> [TerminalFont] { fonts }
    func fetchTerminalFontPreference() async throws -> TerminalFontPreference? { preference }
}

@MainActor
private final class TerminalFontQueueStub: TerminalFontMutationQueue {
    private(set) var fonts: [TerminalFont] = []
    private(set) var preferences: [TerminalFontPreference] = []

    func enqueueTerminalFontUpsert(_ font: TerminalFont) throws {
        fonts.append(font)
    }

    func enqueueTerminalFontPreferenceUpsert(_ preference: TerminalFontPreference) throws {
        preferences.append(preference)
    }

    func drainPendingMutations() async {}
}

@MainActor
private final class TerminalFontLifecycleStub: TerminalFontSyncLifecycle {
    func observe(_ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void) -> UUID { UUID() }
    func removeObserver(_ id: UUID) {}
}

@MainActor
struct TerminalFontStoreTests {
    @Test
    func invalidStoredPreferenceIsReset() {
        let repository = TerminalFontRepositoryStub(
            preference: TerminalFontPreference(
                primaryFamily: String(repeating: "a", count: 257),
                cjkFamily: nil,
                updatedAt: .distantPast
            )
        )

        let store = makeStore(repository: repository)

        #expect(store.preference == .defaultValue)
        #expect(repository.preference == .defaultValue)
    }

    @Test
    func automaticCJKIsStoredAsNoOverride() throws {
        let font = makeFont()
        let repository = TerminalFontRepositoryStub(
            fonts: [font],
            preference: TerminalFontPreference(
                primaryFamily: font.displayName,
                cjkFamily: font.displayName,
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )
        let store = makeStore(repository: repository)

        try store.selectCJKFamily(nil, allowsProFeatures: true)

        #expect(store.preference.cjkFamily == nil)
        #expect(repository.preference.cjkFamily == nil)
    }

    @Test
    func blankCJKSelectionAlsoUsesAutomaticFallbacks() throws {
        let repository = TerminalFontRepositoryStub()
        let store = makeStore(repository: repository)

        try store.selectCJKFamily("   ", allowsProFeatures: false)

        #expect(repository.preference.cjkFamily == nil)
    }

    @Test
    func deletingSelectedFontCreatesTombstoneAndRestoresAutomaticFallbacks() {
        let font = makeFont()
        let repository = TerminalFontRepositoryStub(
            fonts: [font],
            preference: TerminalFontPreference(
                primaryFamily: font.displayName,
                cjkFamily: font.displayName,
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )
        let store = makeStore(repository: repository)

        store.deleteFont(id: font.id)

        #expect(store.customFonts.isEmpty)
        #expect(store.fontRecords.first?.isDeleted == true)
        #expect(store.preference.primaryFamily == TerminalDefaults.defaultFontName)
        #expect(store.preference.cjkFamily == nil)
        #expect(repository.preference.primaryFamily == TerminalDefaults.defaultFontName)
        #expect(repository.preference.cjkFamily == nil)
        #expect(repository.removedFontIDs == [font.id])
    }

    @Test
    func reimportReplacesExistingRecord() throws {
        let existing = makeFont()
        let duplicate = TerminalFont(
            familyNames: existing.familyNames,
            originalFilename: "Renamed.ttf",
            fileSize: existing.fileSize,
            sha256: existing.sha256,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let repository = TerminalFontRepositoryStub(fonts: [existing])
        repository.imported = duplicate
        let store = makeStore(repository: repository)

        let result = try store.importFont(
            from: URL(fileURLWithPath: "/duplicate.ttf"),
            allowsProFeatures: true
        )

        #expect(result == duplicate)
        #expect(store.customFonts == [duplicate])
        #expect(repository.removedFontIDs.isEmpty)
    }

    @Test
    func cloudPreferenceUpdatesPublishedSelection() async throws {
        let font = makeFont()
        let repository = TerminalFontRepositoryStub(fonts: [font])
        let cloud = TerminalFontCloudStub()
        cloud.preference = TerminalFontPreference(
            primaryFamily: font.displayName,
            cjkFamily: font.displayName,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let store = makeStore(
            repository: repository,
            cloud: cloud,
            isSyncEnabled: true
        )

        try await store.synchronizeWithCloud()

        #expect(store.preference == cloud.preference)
        #expect(repository.preference == cloud.preference)
    }

    private func makeStore(
        repository: TerminalFontRepositoryStub,
        cloud: TerminalFontCloudStub = TerminalFontCloudStub(),
        isSyncEnabled: Bool = false
    ) -> TerminalFontStore {
        TerminalFontStore(
            dependencies: TerminalFontStoreDependencies(
                repository: repository,
                cloud: cloud,
                mutationQueue: TerminalFontQueueStub(),
                syncLifecycle: TerminalFontLifecycleStub(),
                loadCatalog: { customFamilies in
                    TerminalFontCatalog(
                        families: [
                            TerminalFontFamily(
                                name: TerminalDefaults.defaultFontName,
                                source: .builtIn
                            )
                        ] + customFamilies
                    )
                },
                isSyncEnabled: { isSyncEnabled },
                now: { Date(timeIntervalSince1970: 100) },
                startsSynchronization: false
            )
        )
    }

    private func makeFont() -> TerminalFont {
        TerminalFont(
            familyNames: ["Test Custom Font"],
            originalFilename: "TestCustomFont.ttf",
            fileSize: 1_024,
            sha256: String(repeating: "d", count: 64),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }
}
