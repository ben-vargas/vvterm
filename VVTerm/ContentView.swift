//
//  ContentView.swift
//  VVTerm
//

import SwiftUI

struct ContentView: View {
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var tabManager = TerminalTabManager.shared
    @StateObject private var storeManager = StoreManager.shared

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var restoredColumnVisibility: NavigationSplitViewVisibility = .all
    @SceneStorage("vvterm.zenMode.macos") private var isZenModeEnabled = false

    /// Whether the selected server is connected
    private var isSelectedServerConnected: Bool {
        guard let selected = selectedServer else { return false }
        return tabManager.connectedServerIds.contains(selected.id)
    }

    /// Whether we have any connected servers
    private var hasConnectedServers: Bool {
        !tabManager.connectedServerIds.isEmpty
    }

    private var canUseZenMode: Bool {
        selectedServer != nil && isSelectedServerConnected
    }

    private var effectiveZenModeEnabled: Bool {
        canUseZenMode && isZenModeEnabled
    }

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    @ViewBuilder
    private var detailContent: some View {
        if let server = selectedServer {
            // A server is selected
            if isSelectedServerConnected {
                // Server is connected - show its terminal container
                ConnectionTerminalContainer(
                    tabManager: tabManager,
                    serverManager: serverManager,
                    server: server,
                    isZenModeEnabled: $isZenModeEnabled,
                    isSidebarVisible: isSidebarVisible,
                    onToggleSidebar: toggleSidebarInZenMode
                )
                .id(server.id) // Ensure isolation per server
            } else if !hasConnectedServers {
                // Not connected to any server - can connect freely
                ServerConnectEmptyState(server: server) {
                    connectToServer(server)
                }
            } else if storeManager.isPro {
                // Pro user already connected to other servers - can connect to more
                ServerConnectEmptyState(server: server) {
                    connectToServer(server)
                }
            } else {
                // Free user already connected to different server - show upgrade
                MultiConnectionUpgradeEmptyState(server: server)
            }
        } else {
            // Nothing selected
            NoServerSelectedEmptyState()
        }
    }

    private func connectToServer(_ server: Server) {
        Task { @MainActor in
            guard await AppLockManager.shared.ensureServerUnlocked(server) else { return }
            tabManager.selectedViewByServer[server.id] = "stats"
            tabManager.connectedServerIds.insert(server.id)
        }
    }

    private func applyZenPresentation(_ enabled: Bool) {
        if enabled {
            if columnVisibility != .detailOnly {
                restoredColumnVisibility = columnVisibility
            }
            columnVisibility = .detailOnly
        } else if columnVisibility == .detailOnly {
            columnVisibility = restoredColumnVisibility == .detailOnly ? .all : restoredColumnVisibility
        }
    }

    private func setZenMode(_ enabled: Bool) {
        guard enabled != isZenModeEnabled else { return }
        applyZenPresentation(enabled)
        isZenModeEnabled = enabled
    }

    private func toggleZenMode() {
        guard canUseZenMode || isZenModeEnabled else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            setZenMode(!isZenModeEnabled)
        }
    }

    private func setSidebarVisible(_ isVisible: Bool) {
        if isVisible {
            columnVisibility = restoredColumnVisibility == .detailOnly ? .all : restoredColumnVisibility
        } else {
            if columnVisibility != .detailOnly {
                restoredColumnVisibility = columnVisibility
            }
            columnVisibility = .detailOnly
        }
    }

    private func toggleSidebarInZenMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            setSidebarVisible(!isSidebarVisible)
        }
    }

    private var zenToggleAction: (() -> Void)? {
        guard canUseZenMode else { return nil }
        return { toggleZenMode() }
    }

    private var splitViewContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // LEFT: Sidebar with workspace + servers
            ServerSidebarView(
                serverManager: serverManager,
                selectedWorkspace: $selectedWorkspace,
                selectedServer: $selectedServer
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            // RIGHT: Detail view based on selection state
            detailContent
        }
        .onAppear {
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
            if !canUseZenMode {
                setZenMode(false)
            } else if isZenModeEnabled {
                applyZenPresentation(true)
            }
        }
        .onChange(of: serverManager.workspaces) { workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        .onChange(of: columnVisibility) { newValue in
            if !isZenModeEnabled && newValue != .detailOnly {
                restoredColumnVisibility = newValue
            }
        }
        .onChange(of: isZenModeEnabled) { enabled in
            applyZenPresentation(enabled && canUseZenMode)
        }
        .onChange(of: canUseZenMode) { available in
            if !available && isZenModeEnabled {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setZenMode(false)
                }
            }
        }
    }

    var body: some View {
        #if os(macOS)
        splitViewContent
            .toolbar(effectiveZenModeEnabled ? .hidden : .visible, for: .windowToolbar)
            .focusedValue(\.toggleZenMode, zenToggleAction)
            .focusedValue(\.isZenModeEnabled, canUseZenMode ? effectiveZenModeEnabled : nil)
            .frame(minWidth: 800, minHeight: 500)
        #endif
        #if !os(macOS)
        splitViewContent
        #endif
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
