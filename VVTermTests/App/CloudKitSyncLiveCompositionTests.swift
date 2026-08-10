import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class AppServerMutationClientStub: ServerRemoteMutationClient {
    func saveServer(_ server: Server) async throws {}
    func deleteServer(_ server: Server) async throws {}
    func saveWorkspace(_ workspace: Workspace) async throws {}
    func deleteWorkspace(_ workspace: Workspace) async throws {}
}

@MainActor
private final class AppThemeMutationClientStub: TerminalThemeCloudMutationClient {
    func saveTerminalTheme(_ theme: TerminalTheme) async throws {}
    func saveTerminalThemePreference(_ preference: TerminalThemePreference) async throws {}
}

@MainActor
private final class AppAccessoryCloudClientStub: TerminalAccessoryCloudClient {
    func syncTerminalAccessoryProfile(
        _ localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
        localProfile
    }
}

@MainActor
private final class AppStatsCloudClientStub: StatsPreferencesCloudClient {
    func syncStatsPreferences(
        _ localPreferences: StatsPreferences
    ) async throws -> StatsPreferences {
        localPreferences
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
}
