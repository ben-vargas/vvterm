//
//  ConnectionTabsView.swift
//  VVTerm
//

import SwiftUI

// MARK: - Connection Terminal Container

struct ConnectionTerminalContainer: View {
    @ObservedObject var tabManager: TerminalTabManager
    @ObservedObject var fileTabManager: RemoteFileTabManager
    let serverManager: ServerManager
    let fileBrowser: RemoteFileBrowserStore
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    let statsDependencies: ServerStatsScreenDependencies
    let terminalSecurityActions: TerminalSecurityActions
    let server: Server
    @Binding var isZenModeEnabled: Bool
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void
    let onOpenSettings: (() -> Void)?
    let onLeaveRoute: (() -> Void)?
    let onDisconnectRoute: (() -> Void)?

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager
    #if os(macOS)
    @EnvironmentObject var commandBridge: MacShellCommandBridge
    #endif
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var viewTabConfig: ViewTabConfigurationManager

    #if os(iOS)
    @AppStorage(TerminalDefaults.preserveTerminalSizeForKeyboardKey) var preservesTerminalSizeForKeyboard = false
    #endif

    /// Disconnect confirmation
    @State var showingDisconnectConfirmation = false
    /// Confirmation before closing the focused split pane via a command/panel
    /// (the in-pane close button has its own confirmation in TerminalTabView).
    @State var showingPaneCloseConfirmation = false
    @State var serverToEdit: Server?

    /// Tab limit alert
    @State private var showingTabLimitAlert = false
    @State var showingFileTabLimitAlert = false
    @State var showingSplitPaneUpgradeAlert = false
    @State var showingZenPanel = false
    #if os(macOS)
    @State var zenWindowSafeAreaInsets = EdgeInsets()
    #endif

    /// Selected view type - persisted per server
    var selectedView: ConnectionViewTabID {
        viewTabConfig.effectiveView(for: tabManager.selectedView(for: server.id))
    }

    var visibleViewTabs: [ConnectionViewTabID] {
        viewTabConfig.currentVisibleTabs
    }

    var shouldShowViewPicker: Bool {
        visibleViewTabs.count > 1
    }

    var terminalAppearance: TerminalColorAppearance {
        colorScheme == .dark ? .dark : .light
    }

    var terminalAppearanceSnapshot: TerminalAppearanceSnapshot {
        terminalThemeManager.appearanceSnapshot(for: terminalAppearance)
    }

    var selectedViewBinding: Binding<ConnectionViewTabID> {
        Binding(
            get: { viewTabConfig.effectiveView(for: tabManager.selectedView(for: server.id)) },
            set: { newValue in
                let current = viewTabConfig.effectiveView(for: tabManager.selectedView(for: server.id))
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectView(viewTabConfig.effectiveView(for: newValue), for: server.id)
                }
            }
        )
    }

    /// Tabs for THIS server only
    var serverTabs: [TerminalTab] {
        tabManager.tabs(for: server.id)
    }

    /// Effective selected tab ID for this server.
    var selectedTabId: UUID? {
        if let selectedId = tabManager.selectedTabId(for: server.id),
           serverTabs.contains(where: { $0.id == selectedId }) {
            return selectedId
        }
        return serverTabs.first?.id
    }

    var selectedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { selectedTabId },
            set: { newValue in
                let validId = newValue.flatMap { requestedId in
                    serverTabs.contains(where: { $0.id == requestedId }) ? requestedId : serverTabs.first?.id
                }
                guard tabManager.selectedTabId(for: server.id) != validId else { return }
                tabManager.selectTab(validId, for: server.id)
            }
        )
    }

    /// Currently selected tab
    var selectedTab: TerminalTab? {
        guard let id = selectedTabId else { return serverTabs.first }
        return serverTabs.first { $0.id == id } ?? serverTabs.first
    }

    var serverFileTabs: [RemoteFileTab] {
        fileTabManager.tabs(for: server.id)
    }

    var selectedFileTabId: UUID? {
        fileTabManager.selectedTab(for: server.id)?.id
    }

    var selectedFileTabIdBinding: Binding<UUID?> {
        Binding(
            get: { selectedFileTabId },
            set: { newValue in
                guard let newValue,
                      let tab = serverFileTabs.first(where: { $0.id == newValue }) else {
                    return
                }
                DispatchQueue.main.async {
                    fileTabManager.selectTab(tab)
                }
            }
        )
    }

    var selectedFileTab: RemoteFileTab? {
        fileTabManager.selectedTab(for: server.id)
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = tabManager.tmuxCoordinator.attachPrompt else { return nil }
                guard tabManager.paneState(for: prompt.paneId)?.serverId == server.id else { return nil }
                return prompt
            },
            set: { newValue in
                guard newValue == nil,
                      let prompt = tabManager.tmuxCoordinator.attachPrompt else { return }
                guard tabManager.paneState(for: prompt.paneId)?.serverId == server.id else { return }
                tabManager.tmuxCoordinator.cancelPrompt(requestId: prompt.id)
            }
        )
    }

    private var liveTerminalBackgroundColor: Color {
        Color.fromHex(terminalAppearanceSnapshot.activeTheme.palette.backgroundHex)
    }

    var sharedBody: some View {
        let backgroundColor = liveTerminalBackgroundColor

        return platformChrome(
            contentLayer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundColor),
            backgroundColor: backgroundColor
        )
            .onAppear {
                repairSelectedTabSelectionIfNeeded()
                handleSelectedViewChange(selectedView)
                ensureInitialFileTabIfNeeded()
            }
            .task(id: terminalAppearanceSnapshot) {
                let snapshot = terminalThemeManager.activateAppearance(terminalAppearance)
                ghosttyApp.applyAppearance(snapshot)
            }
            .onChange(of: selectedView) { newValue in
                handleSelectedViewChange(newValue)
                ensureInitialFileTabIfNeeded()
            }
            .onChangeCompat(of: serverTabs.map(\.id)) { _ in
                repairSelectedTabSelectionIfNeeded()
            }
            .onChange(of: isZenModeEnabled) { newValue in
                if !newValue {
                    showingZenPanel = false
                }
            }
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .limitReachedAlert(.fileTabs, isPresented: $showingFileTabLimitAlert)
            .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
    }

    @ViewBuilder
    private var contentLayer: some View {
        #if os(iOS)
        // View switches must swap content without implicit animations: animating
        // the insertion of the Metal-backed terminal view during the segmented
        // picker's transition hangs the main thread in a trait-update loop.
        platformContentStack
            .transaction { transaction in
                transaction.animation = nil
            }
        #else
        contentStack
        #endif
    }

    @ViewBuilder
    private var contentStack: some View {
        ZStack {
            statsLayer

            if selectedView == .files {
                filesLayer
            }

            terminalLayer
        }
    }

    @ViewBuilder
    var filesLayer: some View {
        if let selectedFileTab {
            RemoteFileBrowserScreen(
                browser: fileBrowser,
                server: server,
                fileTab: selectedFileTab,
                initialPath: selectedFileTab.seedPath
            ) { currentPath in
                fileTabManager.updateLastKnownPath(currentPath, for: selectedFileTab.id)
            }
            .id(selectedFileTab.id)
            .zIndex(1)
        } else {
            RemoteFileTabsEmptyState(server: server) {
                openNewFileTab(selectFilesViewOnSuccess: false)
            }
            .zIndex(1)
        }
    }

    @ViewBuilder
    var statsLayer: some View {
        #if os(iOS)
        // Mount stats only while selected. The dashboard nests ViewThatFits,
        // Grid, and lazy stacks; keeping it in the ZStack at opacity 0 makes
        // every layout pass of the other views re-measure it, which explodes
        // combinatorially and hangs the main thread when the terminal mounts.
        if selectedView == .stats {
            ServerStatsView(
                server: server,
                isVisible: true,
                backgroundColor: liveTerminalBackgroundColor,
                sharedClientProvider: { tabManager.sharedStatsClient(for: server.id) },
                dependencies: statsDependencies,
                isDockerUnlocked: storeManager.isPro
            )
            .zIndex(1)
        }
        #else
        // Stats view - always in hierarchy, visibility controlled by opacity
        // Pass isVisible to pause/resume collection when hidden
        ServerStatsView(
            server: server,
            isVisible: selectedView == .stats,
            backgroundColor: liveTerminalBackgroundColor,
            sharedClientProvider: { tabManager.sharedStatsClient(for: server.id) },
            dependencies: statsDependencies,
            isDockerUnlocked: storeManager.isPro
        )
            .opacity(selectedView == .stats ? 1 : 0)
            .allowsHitTesting(selectedView == .stats)
            .zIndex(selectedView == .stats ? 1 : 0)
        #endif
    }

    var body: some View {
        platformBody
            .sheet(item: tmuxAttachPromptBinding) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        tabManager.tmuxCoordinator.resolvePrompt(
                            requestId: prompt.id,
                            selection: selection
                        )
                    }
                )
                .adaptiveSoftScrollEdges()
            }
    }

    func handleNewTabCommand() {
        if selectedView == .files {
            openNewFileTab(selectFilesViewOnSuccess: true)
        } else {
            openNewTab(selectTerminalViewOnSuccess: true)
        }
    }

    private func ensureInitialFileTabIfNeeded() {
        guard selectedView == .files else { return }

        let seedPath = selectedTab.flatMap { tabManager.workingDirectory(for: $0.focusedPaneId) }
        DispatchQueue.main.async {
            guard selectedView == .files else { return }
            guard let fileTab = fileTabManager.ensureInitialTab(
                for: server,
                seedPath: seedPath,
                hasProAccess: storeManager.isPro
            ) else { return }
            fileBrowser.prepareNewTab(fileTab, duplicating: nil)
        }
    }

    private func repairSelectedTabSelectionIfNeeded() {
        let currentId = tabManager.selectedTabId(for: server.id)
        let repairedId = selectedTabId
        guard currentId != repairedId else { return }
        tabManager.selectTab(repairedId, for: server.id)
    }

    private func handleSelectedViewChange(_ selectedView: ConnectionViewTabID) {
        #if os(iOS)
        guard selectedView != .terminal else { return }
        for tab in serverTabs {
            for paneId in tab.allPaneIds {
                tabManager.applyTerminalVoiceEvent(.pendingReturnDismissed, for: paneId)
            }
        }
        #endif
    }

    func openNewTab(selectTerminalViewOnSuccess: Bool = false) {
        guard tabManager.canOpenNewTab(hasProAccess: storeManager.isPro) else {
            showingTabLimitAlert = true
            return
        }

        Task {
            do {
                let tab = try await tabManager.openTab(for: server)
                await MainActor.run {
                    if selectTerminalViewOnSuccess {
                        tabManager.selectView(viewTabConfig.effectiveView(for: .terminal), for: server.id)
                    }
                    selectedTabIdBinding.wrappedValue = tab.id
                }
            } catch {
                // No-op: user cancelled biometric auth or open failed.
            }
        }
    }

    func openNewFileTab(selectFilesViewOnSuccess: Bool = false) {
        guard fileTabManager.canOpenNewTab(
            for: server.id,
            hasProAccess: storeManager.isPro
        ) else {
            showingFileTabLimitAlert = true
            return
        }

        let sourceTab = selectedFileTab
        let seedPath = sourceTab.flatMap { fileBrowser.lastVisitedPath(for: $0) }
            ?? selectedTab.flatMap { tabManager.workingDirectory(for: $0.focusedPaneId) }
        let newTab = sourceTab.flatMap {
            fileTabManager.duplicateTab(
                $0,
                seedPath: seedPath,
                hasProAccess: storeManager.isPro
            )
        } ?? fileTabManager.openTab(
            for: server,
            seedPath: seedPath,
            hasProAccess: storeManager.isPro
        )

        guard let newTab else { return }
        fileBrowser.prepareNewTab(newTab, duplicating: sourceTab)

        if selectFilesViewOnSuccess {
            tabManager.selectView(viewTabConfig.effectiveView(for: .files), for: server.id)
        }
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex - 1].id
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < serverTabs.count - 1 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex + 1].id
    }

    func selectPreviousFileTab() {
        fileTabManager.selectPreviousTab(for: server.id)
    }

    func selectNextFileTab() {
        fileTabManager.selectNextTab(for: server.id)
    }

    private func baseFileTabTitle(for tab: RemoteFileTab) -> String {
        let candidatePath = fileBrowser.lastVisitedPath(for: tab)
            ?? tab.lastKnownPath
            ?? tab.seedPath

        guard let candidatePath else {
            return server.name.nonEmptyString ?? "/"
        }

        let normalizedPath = RemoteFilePath.normalize(candidatePath)
        guard normalizedPath != "/" else {
            return server.name.nonEmptyString ?? "/"
        }

        return RemoteFilePath.breadcrumbs(for: normalizedPath).last?.title ?? (server.name.nonEmptyString ?? "/")
    }

    func displayedFileTabTitle(for tab: RemoteFileTab) -> String {
        let baseTitles = Dictionary(
            uniqueKeysWithValues: serverFileTabs.map { ($0.id, baseFileTabTitle(for: $0)) }
        )
        let titleCounts = Dictionary(grouping: baseTitles.values, by: { $0 }).mapValues(\.count)
        var seenCounts: [String: Int] = [:]
        var resolvedTitles: [UUID: String] = [:]

        for tab in serverFileTabs {
            let baseTitle = baseTitles[tab.id] ?? (server.name.nonEmptyString ?? "/")
            guard (titleCounts[baseTitle] ?? 0) > 1 else {
                resolvedTitles[tab.id] = baseTitle
                continue
            }

            seenCounts[baseTitle, default: 0] += 1
            resolvedTitles[tab.id] = "\(baseTitle) (\(seenCounts[baseTitle, default: 0]))"
        }

        return resolvedTitles[tab.id] ?? baseFileTabTitle(for: tab)
    }

    private func closeSelectedFileTab() {
        guard let selectedFileTab,
              let removedTab = fileTabManager.closeTab(selectedFileTab) else {
            return
        }
        fileBrowser.removeState(for: removedTab.id)
    }

    func serverViewTabActions() -> ServerViewTabActions {
        ServerViewTabActions(
            openNew: handleNewTabCommand,
            closeSelected: {
                if selectedView == .files {
                    closeSelectedFileTab()
                } else if let selectedTab {
                    // Close the focused split pane first (with confirmation,
                    // since it terminates an SSH connection); only close the
                    // whole tab once it's the last remaining pane.
                    if selectedTab.paneCount > 1 {
                        requestCloseFocusedPane()
                    } else {
                        tabManager.closeTab(selectedTab)
                    }
                }
            },
            selectPrevious: {
                if selectedView == .files {
                    selectPreviousFileTab()
                } else {
                    selectPreviousTab()
                }
            },
            selectNext: {
                if selectedView == .files {
                    selectNextFileTab()
                } else {
                    selectNextTab()
                }
            },
            selectIndex: { index in
                if selectedView == .files {
                    selectFileTab(at: index)
                } else {
                    selectTab(at: index)
                }
            }
        )
    }

    private func selectTab(at index: Int) {
        guard serverTabs.indices.contains(index) else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[index].id
    }

    private func selectFileTab(at index: Int) {
        guard serverFileTabs.indices.contains(index) else { return }
        fileTabManager.selectTab(serverFileTabs[index])
    }

    /// Ask before closing the focused pane (terminates its SSH connection),
    /// matching the in-pane close button's confirmation.
    func requestCloseFocusedPane() {
        guard selectedTab != nil else { return }
        #if os(iOS)
        tabManager.keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
        #endif
        showingPaneCloseConfirmation = true
    }

    func closeFocusedPaneConfirmed() {
        guard let selectedTab else { return }
        tabManager.closePane(tab: selectedTab, paneId: selectedTab.focusedPaneId)
    }

}
