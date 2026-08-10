import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class AppServerMutationClientStub: ServerRemoteMutationClient {
    private(set) var events: [String] = []

    func saveServer(_ server: Server) async throws {
        events.append("saveServer:\(server.id)")
    }

    func deleteServer(_ server: Server) async throws {
        events.append("deleteServer:\(server.id)")
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        events.append("saveWorkspace:\(workspace.id)")
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        events.append("deleteWorkspace:\(workspace.id)")
    }
}

@MainActor
private final class AppThemeMutationClientStub: TerminalThemeCloudMutationClient {
    private(set) var themes: [TerminalTheme] = []
    private(set) var preferences: [TerminalThemePreference] = []

    func saveTerminalTheme(_ theme: TerminalTheme) async throws {
        themes.append(theme)
    }

    func saveTerminalThemePreference(_ preference: TerminalThemePreference) async throws {
        preferences.append(preference)
    }
}

@MainActor
private final class AppAccessoryCloudClientStub: TerminalAccessoryCloudClient {
    private(set) var profiles: [TerminalAccessoryProfile] = []

    func syncTerminalAccessoryProfile(
        _ localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
        profiles.append(localProfile)
        return localProfile
    }
}

@MainActor
private final class AppStatsCloudClientStub: StatsPreferencesCloudClient {
    private(set) var preferences: [StatsPreferences] = []

    func syncStatsPreferences(
        _ localPreferences: StatsPreferences
    ) async throws -> StatsPreferences {
        preferences.append(localPreferences)
        return localPreferences
    }
}

@MainActor
struct CloudKitSyncLiveCompositionTests {
    @Test
    func clientCompositionPreservesInjectedIdentities() {
        let suiteName = "CloudKitSyncLiveCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let server = AppServerMutationClientStub()
        let theme = AppThemeMutationClientStub()
        let accessory = AppAccessoryCloudClientStub()
        let stats = AppStatsCloudClientStub()
        let clients = CloudKitSyncClients(
            serverCloud: server,
            terminalThemeCloud: theme,
            terminalAccessoryCloud: accessory,
            statsPreferencesCloud: stats
        )
        let coordinator = CloudKitSyncLiveComposition.makeCoordinator(
            clients: clients,
            queue: PendingCloudKitSyncQueue(
                storageKey: "compositionQueue",
                defaults: defaults
            ),
            resolutionHub: CloudKitSyncResolutionHub(),
            isSyncEnabled: { false },
            now: { Date(timeIntervalSinceReferenceDate: 1_000) }
        )

        #expect(clients.serverCloud === server)
        #expect(clients.terminalThemeCloud === theme)
        #expect(clients.terminalAccessoryCloud === accessory)
        #expect(clients.statsPreferencesCloud === stats)
        #expect(coordinator.snapshot().isEmpty)
    }

    @Test
    func coordinatorDispatchesEveryMutationAndPublishesResolvedValues() async {
        let suiteName = "CloudKitSyncDispatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let serverClient = AppServerMutationClientStub()
        let themeClient = AppThemeMutationClientStub()
        let accessoryClient = AppAccessoryCloudClientStub()
        let statsClient = AppStatsCloudClientStub()
        let resolutionHub = CloudKitSyncResolutionHub()
        var publishedProfiles: [TerminalAccessoryProfile] = []
        var publishedStats: [StatsPreferences] = []
        let observerID = resolutionHub.observe { resolution in
            switch resolution {
            case .terminalAccessoryProfile(let profile):
                publishedProfiles.append(profile)
            case .statsPreferences(let preferences):
                publishedStats.append(preferences)
            }
        }
        defer { resolutionHub.removeObserver(observerID) }
        let coordinator = CloudKitSyncLiveComposition.makeCoordinator(
            clients: CloudKitSyncClients(
                serverCloud: serverClient,
                terminalThemeCloud: themeClient,
                terminalAccessoryCloud: accessoryClient,
                statsPreferencesCloud: statsClient
            ),
            queue: PendingCloudKitSyncQueue(
                storageKey: "dispatchQueue",
                defaults: defaults
            ),
            resolutionHub: resolutionHub,
            isSyncEnabled: { true },
            now: { Date(timeIntervalSinceReferenceDate: 10_000) }
        )
        let workspace = makeWorkspace(name: "Saved Workspace")
        let deletedWorkspace = makeWorkspace(name: "Deleted Workspace")
        let server = makeServer(workspaceID: workspace.id, name: "Saved Server")
        let deletedServer = makeServer(
            workspaceID: deletedWorkspace.id,
            name: "Deleted Server"
        )
        let theme = TerminalTheme(
            name: "Queued Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let preference = TerminalThemePreference(
            darkThemeName: "Queued Theme",
            lightThemeName: "Queued Theme",
            usePerAppearanceTheme: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let profile = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "device")
        let stats = StatsPreferences(
            style: .cardsCompact,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(timeIntervalSinceReferenceDate: 300),
            lastWriterDeviceId: "device"
        )

        coordinator.enqueueServerUpsert(server)
        coordinator.enqueueServerDelete(deletedServer)
        coordinator.enqueueWorkspaceUpsert(workspace)
        coordinator.enqueueWorkspaceDelete(deletedWorkspace)
        coordinator.enqueueTerminalThemeUpsert(theme)
        coordinator.enqueueTerminalThemePreferenceUpsert(preference)
        coordinator.enqueueTerminalAccessoryProfileUpsert(profile)
        coordinator.enqueueStatsPreferencesUpsert(stats)
        await coordinator.drainPendingMutations()

        #expect(serverClient.events == [
            "saveWorkspace:\(workspace.id)",
            "saveServer:\(server.id)",
            "deleteServer:\(deletedServer.id)",
            "deleteWorkspace:\(deletedWorkspace.id)"
        ])
        #expect(themeClient.themes == [theme])
        #expect(themeClient.preferences == [preference])
        #expect(accessoryClient.profiles == [profile])
        #expect(statsClient.preferences == [stats])
        #expect(publishedProfiles == [profile])
        #expect(publishedStats == [stats])
        #expect(coordinator.snapshot().isEmpty)
    }

    private func makeServer(workspaceID: UUID, name: String) -> Server {
        Server(
            workspaceId: workspaceID,
            name: name,
            host: "server.example.test",
            username: "tester"
        )
    }

    private func makeWorkspace(name: String) -> Workspace {
        Workspace(name: name)
    }
}
