import Foundation

nonisolated struct ServerManagerSnapshot: Equatable, Sendable {
    var servers: [Server]
    var workspaces: [Workspace]
    var loadState: ServerDataLoadState
    var localStorageIssues: [ServerLocalStorageIssue]
    var freePlanGeneration: FreePlanGeneration

    init(
        servers: [Server] = [],
        workspaces: [Workspace] = [],
        loadState: ServerDataLoadState = ServerDataLoadState(),
        localStorageIssues: [ServerLocalStorageIssue] = [],
        freePlanGeneration: FreePlanGeneration
    ) {
        self.servers = servers
        self.workspaces = workspaces
        self.loadState = loadState
        self.localStorageIssues = localStorageIssues
        self.freePlanGeneration = freePlanGeneration
    }
}
