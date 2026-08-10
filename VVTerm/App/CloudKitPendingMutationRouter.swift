@MainActor
final class CloudKitPendingMutationRouter: PendingCloudKitMutationHandling {
    private let serverCloud: any ServerRemoteMutationClient
    private let terminalThemeCloud: any TerminalThemeCloudMutationClient
    private let terminalAccessoryHandler: TerminalAccessoryPendingMutationHandler
    private let statsPreferencesHandler: StatsPreferencesPendingMutationHandler

    init(
        serverCloud: any ServerRemoteMutationClient,
        terminalThemeCloud: any TerminalThemeCloudMutationClient,
        terminalAccessoryHandler: TerminalAccessoryPendingMutationHandler,
        statsPreferencesHandler: StatsPreferencesPendingMutationHandler
    ) {
        self.serverCloud = serverCloud
        self.terminalThemeCloud = terminalThemeCloud
        self.terminalAccessoryHandler = terminalAccessoryHandler
        self.statsPreferencesHandler = statsPreferencesHandler
    }

    func handle(_ mutation: PendingCloudKitMutation) async throws {
        switch mutation.payload {
        case .serverUpsert(let server):
            try await serverCloud.saveServer(server)
        case .serverDelete(let server):
            try await serverCloud.deleteServer(server)
        case .workspaceUpsert(let workspace):
            try await serverCloud.saveWorkspace(workspace)
        case .workspaceDelete(let workspace):
            try await serverCloud.deleteWorkspace(workspace)
        case .terminalThemeUpsert(let theme):
            try await terminalThemeCloud.saveTerminalTheme(theme)
        case .terminalThemePreferenceUpsert(let preference):
            try await terminalThemeCloud.saveTerminalThemePreference(preference)
        case .terminalAccessoryProfileUpsert(let profile):
            try await terminalAccessoryHandler.handle(profile)
        case .statsPreferencesUpsert(let preferences):
            try await statsPreferencesHandler.handle(preferences)
        }
    }
}
