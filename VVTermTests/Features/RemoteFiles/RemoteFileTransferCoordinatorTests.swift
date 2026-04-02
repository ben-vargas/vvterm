import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileTransferCoordinatorTests {
    @Test
    func validatedRemoteNameTrimsWhitespace() throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())

        let result = try store.validatedRemoteName("  notes.txt \n")

        #expect(result == "notes.txt")
    }

    @Test
    func validatedRemoteNameRejectsSlashSeparatedPaths() {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())

        #expect(throws: RemoteFileBrowserError.self) {
            try store.validatedRemoteName("nested/path.txt")
        }
    }

    @Test
    func uniqueTransferEntriesRemovesDuplicatePaths() {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let duplicate = makeEntry(name: "a.txt", path: "/tmp/a.txt")
        let unique = makeEntry(name: "b.txt", path: "/tmp/b.txt")

        let deduped = store.uniqueTransferEntries([duplicate, unique, duplicate])

        #expect(deduped.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    private func makeEntry(name: String, path: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: .file,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileTransferCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
