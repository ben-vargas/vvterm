//
//  ConnectionTabsView.swift
//  VVTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Connection Terminal Container

struct ConnectionTerminalContainer: View {
    @ObservedObject var tabManager: TerminalTabManager
    let serverManager: ServerManager
    let server: Server
    @Binding var isZenModeEnabled: Bool
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var storeManager = StoreManager.shared

    /// Cached terminal background color from theme
    @State private var terminalBackgroundColor: Color = .black

    /// Theme name from settings
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true

    /// Disconnect confirmation
    @State private var showingDisconnectConfirmation = false

    /// Tab limit alert
    @State private var showingTabLimitAlert = false
    @State private var showingZenPanel = false

    /// Selected view type - persisted per server
    private var selectedView: String {
        tabManager.selectedViewByServer[server.id] ?? "stats"
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var selectedViewBinding: Binding<String> {
        Binding(
            get: { tabManager.selectedViewByServer[server.id] ?? "stats" },
            set: { newValue in
                let current = tabManager.selectedViewByServer[server.id] ?? "stats"
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedViewByServer[server.id] = newValue
                }
            }
        )
    }

    /// Tabs for THIS server only
    private var serverTabs: [TerminalTab] {
        tabManager.tabs(for: server.id)
    }

    /// Selected tab ID for this server
    private var selectedTabId: UUID? {
        tabManager.selectedTabByServer[server.id]
    }

    private var selectedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { tabManager.selectedTabByServer[server.id] },
            set: { newValue in
                let current = tabManager.selectedTabByServer[server.id]
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedTabByServer[server.id] = newValue
                }
            }
        )
    }

    /// Currently selected tab
    private var selectedTab: TerminalTab? {
        guard let id = selectedTabId else { return serverTabs.first }
        return serverTabs.first { $0.id == id } ?? serverTabs.first
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = tabManager.tmuxAttachPrompt else { return nil }
                guard tabManager.paneStates[prompt.id]?.serverId == server.id else { return nil }
                return prompt
            },
            set: { newValue in
                guard newValue == nil, let prompt = tabManager.tmuxAttachPrompt else { return }
                guard tabManager.paneStates[prompt.id]?.serverId == server.id else { return }
                tabManager.cancelTmuxAttachPrompt(paneId: prompt.id)
            }
        )
    }

    var body: some View {
        ZStack {
            // Stats view - always in hierarchy, visibility controlled by opacity
            // Pass isVisible to pause/resume collection when hidden
            ServerStatsView(
                server: server,
                isVisible: selectedView == "stats",
                sharedClientProvider: { tabManager.sharedStatsClient(for: server.id) }
            )
                .opacity(selectedView == "stats" ? 1 : 0)
                .allowsHitTesting(selectedView == "stats")
                .zIndex(selectedView == "stats" ? 1 : 0)

            #if os(macOS)
            // Each tab is an isolated terminal view
            ForEach(serverTabs, id: \.id) { tab in
                let isVisible = selectedView == "terminal" && selectedTabId == tab.id
                TerminalTabView(
                    tab: tab,
                    server: server,
                    tabManager: tabManager,
                    isSelected: isVisible
                )
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .zIndex(isVisible ? 1 : 0)
            }

            // Empty state when in terminal view with no tabs
            if selectedView == "terminal" && serverTabs.isEmpty {
                TerminalEmptyStateView(server: server) {
                    openNewTab()
                }
            }
            #else
            if selectedView == "terminal" && serverTabs.isEmpty {
                TerminalEmptyStateView(server: server) {
                    openNewTab()
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selectedView == "terminal" ? terminalBackgroundColor : nil)
        .overlay(alignment: .top) {
            #if os(macOS)
            if selectedView == "terminal" && !isZenModeEnabled {
                MacOSToolbarBackdrop(color: terminalBackgroundColor)
            }
            #endif
        }
        .macOSZenExpandedTopSafeArea(isZenModeEnabled && selectedView == "terminal")
        .onAppear {
            updateTerminalBackgroundColor()
            // Select first tab if none selected
            if selectedTabId == nil {
                selectedTabIdBinding.wrappedValue = serverTabs.first?.id
            }
        }
        .onChange(of: terminalThemeName) { _ in
            updateTerminalBackgroundColor()
        }
        .onChange(of: terminalThemeNameLight) { _ in
            updateTerminalBackgroundColor()
        }
        .onChange(of: usePerAppearanceTheme) { _ in
            updateTerminalBackgroundColor()
        }
        .onChange(of: colorScheme) { _ in
            updateTerminalBackgroundColor()
        }
        .onChange(of: serverTabs.count) { _ in
            // Auto-select if current selection is invalid
            if let currentId = selectedTabId, !serverTabs.contains(where: { $0.id == currentId }) {
                selectedTabIdBinding.wrappedValue = serverTabs.first?.id
            }
        }
        .onChange(of: isZenModeEnabled) { newValue in
            if !newValue {
                showingZenPanel = false
            }
        }
        #if os(macOS)
        .focusedValue(\.openTerminalTab, handleNewTabCommand)
        .toolbar {
            if !isZenModeEnabled {
                viewPickerToolbarItem
                if selectedView == "terminal" && !serverTabs.isEmpty {
                    tabsToolbarItem
                }
                toolbarSpacer
                trailingToolbarItems
            }
        }
        .overlay(alignment: .topTrailing) {
            if isZenModeEnabled {
                zenModeOverlay
            }
        }
        #endif
        .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
        .sheet(item: tmuxAttachPromptBinding) { prompt in
            TmuxAttachPromptSheet(
                prompt: prompt,
                onConfirm: { selection in
                    tabManager.resolveTmuxAttachPrompt(paneId: prompt.id, selection: selection)
                }
            )
        }
    }

    private func handleNewTabCommand() {
        openNewTab(selectTerminalViewOnSuccess: true)
    }

    private func openNewTab(selectTerminalViewOnSuccess: Bool = false) {
        guard tabManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }

        Task {
            do {
                let tab = try await tabManager.openTab(for: server)
                await MainActor.run {
                    if selectTerminalViewOnSuccess {
                        tabManager.selectedViewByServer[server.id] = "terminal"
                    }
                    selectedTabIdBinding.wrappedValue = tab.id
                }
            } catch {
                // No-op: user cancelled biometric auth or open failed.
            }
        }
    }

    private func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex - 1].id
    }

    private func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < serverTabs.count - 1 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex + 1].id
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)
            await MainActor.run {
                if let color = resolved {
                    terminalBackgroundColor = color
                    UserDefaults.standard.set(color.toHex(), forKey: "terminalBackgroundColor")
                } else {
                    #if os(macOS)
                    terminalBackgroundColor = Color(NSColor.windowBackgroundColor)
                    #elseif os(iOS)
                    terminalBackgroundColor = Color(UIColor.systemBackground)
                    #else
                    terminalBackgroundColor = .black
                    #endif
                }
            }
        }
    }

    // MARK: - Toolbar Items (macOS)

    #if os(macOS)
    @ToolbarContentBuilder
    private var viewPickerToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("View", selection: selectedViewBinding) {
                Label("Stats", systemImage: "chart.bar.xaxis")
                    .tag("stats")
                Label("Terminal", systemImage: "terminal")
                    .tag("terminal")
            }
            .pickerStyle(.segmented)
        }
    }

    @ToolbarContentBuilder
    private var tabsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            TerminalTabsScrollView(
                tabs: serverTabs,
                selectedTabId: selectedTabIdBinding,
                onClose: { tab in tabManager.closeTab(tab) },
                onNew: { openNewTab() },
                tabManager: tabManager
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarSpacer: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            zenModeToolbarButton
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .primaryAction) {
                Color.clear
                    .frame(width: 8, height: 1)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            connectionStatusToolbarGroup
        }
    }

    private var zenModeToolbarButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                isZenModeEnabled = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                Text("Zen")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Text("Enter Zen Mode"))
    }

    private var connectionStatusToolbarGroup: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(serverTabs.isEmpty ? Color.secondary : Color.green)
                .frame(width: 8, height: 8)

            Text(compactTabsStatusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Divider()
                .frame(height: 16)

            Button {
                showingDisconnectConfirmation = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(Text("Disconnect from server"))
            .alert(
                disconnectAlertTitle,
                isPresented: $showingDisconnectConfirmation,
            ) {
                Button("Cancel", role: .cancel) {}
                Button(disconnectActionTitle, role: .destructive) {
                    disconnectFromServer()
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(disconnectAlertMessage)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
    }

    private func disconnectFromServer() {
        tabManager.closeAllTabs(for: server.id)
        tabManager.connectedServerIds.remove(server.id)
    }

    private var zenModeOverlay: some View {
        ZenModeFloatingOverlay(
            isPanelPresented: $showingZenPanel,
            indicatorColor: zenIndicatorColor
        ) { panelWidth in
            MacOSZenModePanel(
                width: panelWidth,
                serverName: server.name,
                statusText: tabsStatusText,
                statusColor: zenIndicatorColor,
                selectedView: selectedView,
                selectedViewBinding: selectedViewBinding,
                tabs: serverTabs,
                selectedTabId: selectedTabIdBinding,
                paneState: { tab in
                    tabManager.paneStates[tab.focusedPaneId]
                },
                onPreviousTab: { selectPreviousTab() },
                onNextTab: { selectNextTab() },
                onNewTab: {
                    showingZenPanel = false
                    openNewTab(selectTerminalViewOnSuccess: true)
                },
                onCloseTab: { tab in
                    tabManager.closeTab(tab)
                },
                onSplitRight: {
                    guard let selectedTab else { return }
                    _ = tabManager.splitHorizontal(tab: selectedTab, paneId: selectedTab.focusedPaneId)
                },
                onSplitDown: {
                    guard let selectedTab else { return }
                    _ = tabManager.splitVertical(tab: selectedTab, paneId: selectedTab.focusedPaneId)
                },
                onClosePane: {
                    guard let selectedTab else { return }
                    tabManager.closePane(tab: selectedTab, paneId: selectedTab.focusedPaneId)
                },
                canSplit: selectedTab != nil && storeManager.isPro,
                canClosePane: selectedTab != nil,
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: {
                    showingZenPanel = false
                    onToggleSidebar()
                },
                onDisconnect: {
                    showingZenPanel = false
                    showingDisconnectConfirmation = true
                },
                onExitZen: {
                    showingZenPanel = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isZenModeEnabled = false
                    }
                }
            )
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    #endif
}

private extension View {
    @ViewBuilder
    func macOSZenExpandedTopSafeArea(_ isEnabled: Bool) -> some View {
        #if os(macOS)
        if isEnabled {
            self.ignoresSafeArea(.container, edges: .top)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacOSToolbarBackdrop: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 52
            color
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
        }
        .allowsHitTesting(false)
    }
}

private extension ConnectionTerminalContainer {
    var zenIndicatorColor: Color {
        guard let state = selectedTab.flatMap({ tabManager.paneStates[$0.focusedPaneId] }) else {
            return serverTabs.isEmpty ? .secondary : .green
        }

        switch state.connectionState {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected, .idle:
            return .secondary
        case .failed:
            return .red
        }
    }

    var tabsStatusText: String {
        if serverTabs.isEmpty {
            return String(localized: "No terminals")
        }
        let count = serverTabs.count
        return count == 1
            ? String(format: String(localized: "%lld tab"), count)
            : String(format: String(localized: "%lld tabs"), count)
    }

    var compactTabsStatusText: String {
        let count = serverTabs.count
        return count == 1
            ? String(format: String(localized: "%lld tab"), count)
            : String(format: String(localized: "%lld tabs"), count)
    }

    var disconnectAlertTitle: String {
        String(localized: "Close Tab?")
    }

    var disconnectActionTitle: String {
        String(localized: "Close")
    }

    var disconnectAlertMessage: String {
        serverTabs.isEmpty
            ? String(localized: "This will return to the server list.")
            : String(localized: "All terminal tabs for this server will be closed.")
    }
}
#endif

// MARK: - Terminal Tabs Scroll View

#if os(macOS)
struct TerminalTabsScrollView: View {
    let tabs: [TerminalTab]
    @Binding var selectedTabId: UUID?
    let onClose: (TerminalTab) -> Void
    let onNew: () -> Void
    @ObservedObject var tabManager: TerminalTabManager

    @State private var isNewTabHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Navigation arrows
            HStack(spacing: 4) {
                NavigationArrowButton(
                    icon: "chevron.left",
                    action: { selectPrevious() },
                    help: String(localized: "Previous tab")
                )
                .disabled(tabs.count <= 1)

                NavigationArrowButton(
                    icon: "chevron.right",
                    action: { selectNext() },
                    help: String(localized: "Next tab")
                )
                .disabled(tabs.count <= 1)
            }
            .padding(.leading, 8)

            // Tabs scroll view
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs, id: \.id) { tab in
                        TerminalTabButton(
                            tab: tab,
                            isSelected: selectedTabId == tab.id,
                            onSelect: { selectedTabId = tab.id },
                            onClose: { onClose(tab) },
                            tabManager: tabManager
                        )
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: 600, maxHeight: 36)

            // New tab button
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 24)
                    .background(
                        isNewTabHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .onHover { isNewTabHovering = $0 }
            .help(Text("New terminal tab"))
            .padding(.trailing, 8)
        }
    }

    private func selectPrevious() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabId = tabs[currentIndex - 1].id
    }

    private func selectNext() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < tabs.count - 1 else { return }
        selectedTabId = tabs[currentIndex + 1].id
    }
}

// MARK: - Terminal Tab Button

struct TerminalTabButton: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ObservedObject var tabManager: TerminalTabManager

    @State private var isHovering = false

    /// Get pane state for the focused pane
    private var paneState: TerminalPaneState? {
        tabManager.paneStates[tab.focusedPaneId]
    }

    private var statusColor: Color {
        guard let state = paneState else { return .secondary }
        switch state.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .idle: return .secondary
        case .failed: return .red
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                // Close button (like Aizen's DetailCloseButton)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                        )
                }
                .buttonStyle(.plain)

                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                // Title
                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)

                // Pane count indicator (if splits)
                if tab.paneCount > 1 {
                    Text(verbatim: "⊞")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ?
                Color(nsColor: .separatorColor) :
                (isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
#endif
