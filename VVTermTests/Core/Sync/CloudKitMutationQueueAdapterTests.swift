import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class MutationQueueAdapterHandler: PendingCloudKitMutationHandling {
    func handle(_ mutation: PendingCloudKitMutation) async throws {}
}

@MainActor
struct CloudKitMutationQueueAdapterTests {
    @Test
    func serverAdapterMapsEveryOperationAndClearsOnlyServerMutations() throws {
        let fixture = makeFixture(storageKey: "serverAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let coordinator = fixture.coordinator
        let repository: any ServerSyncRepository = coordinator
        let workspace = makeWorkspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Saved Workspace"
        )
        let deletedWorkspace = makeWorkspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Deleted Workspace"
        )
        let server = makeServer(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceID: workspace.id,
            name: "Saved Server"
        )
        let deletedServer = makeServer(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            workspaceID: deletedWorkspace.id,
            name: "Deleted Server"
        )
        let stats = makeStatsPreferences()
        let unrelatedMutation = PendingCloudKitMutation(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            payload: .statsPreferencesUpsert(stats),
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        coordinator.enqueue(unrelatedMutation)

        repository.enqueueServerUpsert(server)
        repository.enqueueServerDelete(deletedServer)
        repository.enqueueWorkspaceUpsert(workspace)
        repository.enqueueWorkspaceDelete(deletedWorkspace)

        #expect(coordinator.snapshot().map(\.payload) == [
            .statsPreferencesUpsert(stats),
            .serverUpsert(server),
            .serverDelete(deletedServer),
            .workspaceUpsert(workspace),
            .workspaceDelete(deletedWorkspace)
        ])
        #expect(repository.pendingServerMutations().map(\.payload) == [
            .serverUpsert(server),
            .serverDelete(deletedServer),
            .workspaceUpsert(workspace),
            .workspaceDelete(deletedWorkspace)
        ])

        let firstServerMutation = try #require(repository.pendingServerMutations().first)
        repository.removePendingServerMutation(firstServerMutation.id)
        repository.clearPendingServerAndWorkspaceMutations()

        #expect(coordinator.snapshot() == [unrelatedMutation])
    }

    @Test
    func serverAdapterPreservesAtomicDeletionMutationIdentityAndOrder() throws {
        let fixture = makeFixture(storageKey: "serverAtomicAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let repository: any ServerSyncRepository = fixture.coordinator
        let workspace = makeWorkspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            name: "Deleted Workspace"
        )
        let server = makeServer(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
            workspaceID: workspace.id,
            name: "Deleted Server"
        )
        let createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let serverMutation = ServerPendingMutation(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000010")!,
            payload: .serverDelete(server),
            createdAt: createdAt
        )
        let workspaceMutation = ServerPendingMutation(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000011")!,
            payload: .workspaceDelete(workspace),
            createdAt: createdAt
        )

        try repository.enqueueWorkspaceDeletionMutations([
            serverMutation,
            workspaceMutation
        ])

        #expect(fixture.coordinator.snapshot() == [
            PendingCloudKitMutation(
                id: serverMutation.id,
                payload: .serverDelete(server),
                createdAt: createdAt
            ),
            PendingCloudKitMutation(
                id: workspaceMutation.id,
                payload: .workspaceDelete(workspace),
                createdAt: createdAt
            )
        ])
    }

    @Test
    func themeAdapterMapsThemeAndPreferenceUpserts() {
        let fixture = makeFixture(storageKey: "themeAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let queue: any TerminalThemeMutationQueue = fixture.coordinator
        let theme = TerminalTheme(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            name: "Queued Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 3_000)
        )
        let preference = TerminalThemePreference(
            darkThemeName: theme.name,
            lightThemeName: theme.name,
            usePerAppearanceTheme: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 3_001)
        )

        queue.enqueueTerminalThemeUpsert(theme)
        queue.enqueueTerminalThemePreferenceUpsert(preference)

        #expect(fixture.coordinator.snapshot().map(\.payload) == [
            .terminalThemeUpsert(theme),
            .terminalThemePreferenceUpsert(preference)
        ])
    }

    @Test
    func accessoryAdapterMapsProfileUpsert() {
        let fixture = makeFixture(storageKey: "accessoryAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let queue: any TerminalAccessoryMutationQueue = fixture.coordinator
        let profile = TerminalAccessoryProfile.defaultValue(
            lastWriterDeviceId: "accessory-writer"
        )

        queue.enqueueTerminalAccessoryProfileUpsert(profile)

        #expect(fixture.coordinator.snapshot().map(\.payload) == [
            .terminalAccessoryProfileUpsert(profile)
        ])
    }

    @Test
    func statsAdapterMapsPreferencesUpsert() {
        let fixture = makeFixture(storageKey: "statsAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let queue: any StatsPreferencesMutationQueue = fixture.coordinator
        let preferences = makeStatsPreferences()

        queue.enqueueStatsPreferencesUpsert(preferences)

        #expect(fixture.coordinator.snapshot().map(\.payload) == [
            .statsPreferencesUpsert(preferences)
        ])
    }

    private func makeFixture(
        storageKey: String
    ) -> (
        coordinator: CloudKitSyncCoordinator,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "CloudKitMutationQueueAdapterTests.\(storageKey).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (
            CloudKitSyncCoordinator(
                mutationHandler: MutationQueueAdapterHandler(),
                queue: PendingCloudKitSyncQueue(
                    storageKey: storageKey,
                    defaults: defaults
                ),
                isSyncEnabled: { false },
                now: { Date(timeIntervalSinceReferenceDate: 5_000) }
            ),
            defaults,
            suiteName
        )
    }

    private func makeWorkspace(id: UUID, name: String) -> Workspace {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        return Workspace(
            id: id,
            name: name,
            createdAt: date,
            updatedAt: date
        )
    }

    private func makeServer(id: UUID, workspaceID: UUID, name: String) -> Server {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        return Server(
            id: id,
            workspaceId: workspaceID,
            name: name,
            host: "server.example.test",
            username: "tester",
            createdAt: date,
            updatedAt: date
        )
    }

    private func makeStatsPreferences() -> StatsPreferences {
        StatsPreferences(
            style: .cardsCompact,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(timeIntervalSinceReferenceDate: 4_000),
            lastWriterDeviceId: "stats-writer"
        )
    }
}
