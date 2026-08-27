#if DEBUG
import SwiftUI

@MainActor
struct ServerDuplicateUITestHarness: View {
    private static let fallbackWorkspaceID = UUID(
        uuidString: "9B678329-F5FC-4A81-971C-CFCAC3261656"
    )!

    let serverManager: ServerManager
    let dependencies: ServerFormDependencies
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory

    @State private var formIntent: ServerFormIntent?

    private var workspace: Workspace? {
        serverManager.workspaces.first
    }

    private var sourceServer: Server {
        Server(
            id: UUID(uuidString: "4BEE9E2E-E2CF-438C-A44C-B2391D0606E5")!,
            workspaceId: workspace?.id ?? Self.fallbackWorkspaceID,
            name: "DEV-397 UI Test Source",
            host: "duplicate-test.example.com",
            port: 2222,
            username: "wiedy",
            connectionMode: .tailscale,
            notes: "Duplicate form fixture"
        )
    }

    var body: some View {
        NavigationStack {
            List {
                #if os(iOS)
                ServerListRow(
                    serverManager: serverManager,
                    server: sourceServer,
                    onTap: {},
                    onEdit: {},
                    onMove: {},
                    onDuplicate: { formIntent = .duplicate(sourceServer) },
                    onWake: { _ in }
                )
                .accessibilityIdentifier("vvterm.serverDuplicateTest.row")
                #else
                Button {
                    formIntent = .duplicate(sourceServer)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .accessibilityIdentifier("vvterm.serverDuplicateTest.action")
                #endif
            }
            .navigationTitle("Server Duplicate Test")
        }
        .sheet(item: $formIntent) { intent in
            formSheet(for: intent)
        }
        .accessibilityIdentifier("vvterm.serverDuplicateTest.root")
    }

    @ViewBuilder
    private func formSheet(for intent: ServerFormIntent) -> some View {
        #if os(iOS)
        NavigationStack {
            serverForm(for: intent)
        }
        #else
        serverForm(for: intent)
            .frame(
                minWidth: 640,
                idealWidth: 700,
                maxWidth: 760,
                minHeight: 520,
                idealHeight: 620,
                maxHeight: 680
            )
        #endif
    }

    private func serverForm(for intent: ServerFormIntent) -> some View {
        ServerFormSheet(
            serverManager: serverManager,
            workspace: workspace,
            intent: intent,
            dependencies: dependencies,
            makeLocalDiscoveryManager: makeLocalDiscoveryManager,
            onSave: { _ in formIntent = nil }
        )
    }
}
#endif
