import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ServerManagerBootstrapTests {
    @Test
    func bootstrapCreationRunsOnlyBeforeAnyFirstRunMarkerExists() {
        #expect(
            ServerManager.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: false,
                hasLocalWorkspaces: false
            )
        )
    }

    @Test
    func bootstrapCreationIsBlockedByEitherBootstrapFlagOrWelcomeFlag() {
        #expect(
            !ServerManager.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: true,
                hasSeenWelcome: false,
                hasLocalWorkspaces: false
            )
        )
        #expect(
            !ServerManager.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: true,
                hasLocalWorkspaces: false
            )
        )
        #expect(
            !ServerManager.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: false,
                hasLocalWorkspaces: true
            )
        )
    }

    @Test
    func backfillCandidatesIgnoreTransientBootstrapWorkspace() {
        let bootstrapWorkspace = Workspace(
            id: UUID(),
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.en.rawValue),
            order: 0
        )
        let remoteWorkspace = Workspace(id: UUID(), name: "Remote", order: 1)

        let bootstrapServer = Server(
            id: UUID(),
            workspaceId: bootstrapWorkspace.id,
            name: "Placeholder",
            host: "bootstrap.example.com",
            username: "root"
        )
        let remoteServer = Server(
            id: UUID(),
            workspaceId: remoteWorkspace.id,
            name: "Needs Upload",
            host: "remote.example.com",
            username: "root"
        )

        let candidates = ServerManager.backfillCandidates(
            localWorkspaces: [bootstrapWorkspace, remoteWorkspace],
            localServers: [bootstrapServer, remoteServer],
            cloudWorkspaceIDs: [remoteWorkspace.id],
            cloudServerIDs: [],
            transientBootstrapWorkspaceID: bootstrapWorkspace.id
        )

        #expect(candidates.workspaces.isEmpty)
        #expect(candidates.servers.map(\.id) == [remoteServer.id])
    }

    @Test
    func canonicalDefaultWorkspaceDetectionAcceptsLocalizedNames() {
        let localizedWorkspace = Workspace(
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.zhHans.rawValue),
            order: 0
        )

        #expect(ServerManager.isCanonicalDefaultWorkspaceCandidate(localizedWorkspace))
    }

    @Test
    func backfillCandidatesIncludeBootstrapWorkspaceAfterPromotion() {
        let bootstrapWorkspace = Workspace(
            id: UUID(),
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.en.rawValue),
            order: 0
        )

        let candidates = ServerManager.backfillCandidates(
            localWorkspaces: [bootstrapWorkspace],
            localServers: [],
            cloudWorkspaceIDs: [],
            cloudServerIDs: [],
            transientBootstrapWorkspaceID: nil
        )

        #expect(candidates.workspaces.map(\.id) == [bootstrapWorkspace.id])
        #expect(candidates.servers.isEmpty)
    }

    @Test
    func orphanRepairCreatesFallbackWorkspaceWhenServersExistWithoutAnyWorkspace() {
        let orphanedServer = Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "Lost Server",
            host: "lost.example.com",
            username: "root"
        )
        let fallbackWorkspace = Workspace(id: UUID(), name: "My Servers", order: 0)

        let repairWorkspace = ServerManager.workspaceForOrphanRepair(
            existingWorkspaces: [],
            servers: [orphanedServer],
            fallbackWorkspace: fallbackWorkspace
        )

        #expect(repairWorkspace?.id == fallbackWorkspace.id)
    }

    @Test
    func orphanRepairDoesNothingWhenAllServersAlreadyHaveValidWorkspaces() {
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let validServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Healthy",
            host: "healthy.example.com",
            username: "root"
        )
        let fallbackWorkspace = Workspace(id: UUID(), name: "Fallback", order: 1)

        let repairWorkspace = ServerManager.workspaceForOrphanRepair(
            existingWorkspaces: [workspace],
            servers: [validServer],
            fallbackWorkspace: fallbackWorkspace
        )

        #expect(repairWorkspace == nil)
    }
}
