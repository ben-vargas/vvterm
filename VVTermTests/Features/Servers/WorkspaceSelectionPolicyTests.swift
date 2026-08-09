import Foundation
import Testing
@testable import VVTerm

@MainActor
struct WorkspaceSelectionPolicyTests {
    @Test
    func replacesDeletedWorkspaceAndRefreshesExistingWorkspaceValue() throws {
        let firstID = UUID()
        let original = Workspace(id: firstID, name: "Original")
        let refreshed = Workspace(id: firstID, name: "Refreshed")
        let fallback = Workspace(name: "Fallback")

        let matching = try #require(WorkspaceSelectionPolicy.workspace(
            current: original,
            available: [refreshed, fallback]
        ))
        #expect(matching.name == "Refreshed")

        let replacement = try #require(WorkspaceSelectionPolicy.workspace(
            current: Workspace(name: "Deleted"),
            available: [fallback]
        ))
        #expect(replacement.id == fallback.id)
        #expect(WorkspaceSelectionPolicy.workspace(current: original, available: []) == nil)
    }

    @Test
    func removesEnvironmentSelectionThatIsNotInTheWorkspace() {
        let custom = ServerEnvironment(
            name: "Custom",
            shortName: "C",
            colorHex: "#000000"
        )
        let workspace = Workspace(name: "Workspace", environments: [ServerEnvironment.production])

        #expect(WorkspaceSelectionPolicy.environment(
            current: ServerEnvironment.production,
            workspace: workspace
        ) == ServerEnvironment.production)
        #expect(WorkspaceSelectionPolicy.environment(
            current: custom,
            workspace: workspace
        ) == nil)
    }

    @Test
    func storesAndReconcilesFilterIDsByWorkspace() {
        let foreignID = UUID()
        let first = Workspace(
            name: "Workspace",
            environments: [ServerEnvironment.production, ServerEnvironment.staging]
        )
        let secondEnvironment = ServerEnvironment(name: "Second", shortName: "S", colorHex: "#000000")
        let second = Workspace(name: "Second", environments: [secondEnvironment])

        var stored = WorkspaceSelectionPolicy.updatingEnvironmentFilterIDs(
            [ServerEnvironment.production.id, foreignID],
            for: first,
            stored: ""
        )
        stored = WorkspaceSelectionPolicy.updatingEnvironmentFilterIDs(
            [secondEnvironment.id],
            for: second,
            stored: stored
        )

        #expect(WorkspaceSelectionPolicy.environmentFilterIDs(stored: stored, workspace: first) == [
            ServerEnvironment.production.id
        ])
        #expect(WorkspaceSelectionPolicy.environmentFilterIDs(stored: stored, workspace: second).isEmpty)

        let firstWithoutProduction = Workspace(
            id: first.id,
            name: first.name,
            environments: [ServerEnvironment.staging]
        )
        let reconciled = WorkspaceSelectionPolicy.reconciledEnvironmentFilters(
            stored: stored,
            workspaces: [firstWithoutProduction, second]
        )

        #expect(WorkspaceSelectionPolicy.environmentFilterIDs(
            stored: reconciled,
            workspace: firstWithoutProduction
        ).isEmpty)
    }

    @Test
    func migratesLegacyFiltersOnlyToTheCurrentWorkspace() {
        let first = Workspace(
            name: "First",
            environments: [ServerEnvironment.production, ServerEnvironment.staging]
        )
        let second = Workspace(name: "Second", environments: [ServerEnvironment.production])
        let legacy = ServerEnvironment.staging.id.uuidString

        let stored = WorkspaceSelectionPolicy.migratingLegacyEnvironmentFilters(
            legacy,
            to: first,
            stored: ""
        )

        #expect(WorkspaceSelectionPolicy.environmentFilterIDs(stored: stored, workspace: first) == [
            ServerEnvironment.staging.id
        ])
        #expect(WorkspaceSelectionPolicy.environmentFilterIDs(stored: stored, workspace: second).isEmpty)
        #expect(WorkspaceSelectionPolicy.migratingLegacyEnvironmentFilters(
            ServerEnvironment.production.id.uuidString,
            to: second,
            stored: stored
        ) == stored)
    }
}
