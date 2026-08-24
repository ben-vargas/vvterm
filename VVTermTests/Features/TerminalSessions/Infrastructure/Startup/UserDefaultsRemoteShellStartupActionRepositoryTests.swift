import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct UserDefaultsRemoteShellStartupActionRepositoryTests {
    @Test
    func repositoryKeepsCommandsLocalToEachServerAndRemovesDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = UserDefaultsRemoteShellStartupActionRepository(defaults: defaults)
        let firstID = UUID()
        let secondID = UUID()
        let first = try RemoteShellStartupAction(command: "cd ~/first && tmux attach")
        let second = try RemoteShellStartupAction(command: "cd ~/second && zmx attach work")

        repository.save(first, for: firstID)
        repository.save(second, for: secondID)
        #expect(repository.action(for: firstID) == first)
        #expect(repository.action(for: secondID) == second)

        repository.save(nil, for: firstID)
        #expect(repository.action(for: firstID) == nil)
        #expect(repository.action(for: secondID) == second)
        repository.save(nil, for: secondID)
        #expect(defaults.object(
            forKey: UserDefaultsRemoteShellStartupActionRepository.storageKey(
                for: secondID
            )
        ) == nil)
    }

    @Test
    func repositoryDiscardsStructuredOrInvalidStorage() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = UserDefaultsRemoteShellStartupActionRepository(defaults: defaults)
        let serverID = UUID()
        let key = UserDefaultsRemoteShellStartupActionRepository.storageKey(for: serverID)

        defaults.set(["executable": "/bin/old", "arguments": []], forKey: key)
        #expect(repository.action(for: serverID) == nil)
        #expect(defaults.object(forKey: key) == nil)

        defaults.set("printf ready\0", forKey: key)
        #expect(repository.action(for: serverID) == nil)
        #expect(defaults.object(forKey: key) == nil)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "UserDefaultsRemoteShellStartupActionRepositoryTests.\(UUID())"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
