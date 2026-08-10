//
//  TerminalView.swift
//  VVTerm
//
//  Renders a single tab's terminal content (with optional splits).
//  Each tab is isolated - splits happen within the tab, not across tabs.
//

import Foundation
import SwiftUI
import os.log
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Terminal Tab View

/// Renders a single terminal tab with its split layout
struct TerminalTabView: View {
    let tab: TerminalTab
    let server: Server
    @ObservedObject var tabManager: TerminalTabManager
    let securityActions: TerminalSecurityActions
    let isSelected: Bool
    let appearance: TerminalAppearanceSnapshot
    @ObservedObject var voiceSettingsStore: VoiceSettingsStore
    @ObservedObject var audioService: AudioService
    @ObservedObject var voiceRecordingOperation: VoiceRecordingOperationCoordinator

    @State private var layoutVersion: Int = 0
    @State private var showingCloseConfirmation = false
    @State private var showingSplitPaneUpgradeAlert = false

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @EnvironmentObject private var storeManager: StoreManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingPermissionError = false
    @State private var permissionErrorMessage = ""
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    private var dividerColor: Color {
        guard let components = ThemeColorParser.splitDividerComponents(
            for: appearance.activeTheme.palette.backgroundHex
        ) else {
            return Color(white: 0.3)
        }
        return Color(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: components.alpha
        )
    }

    private var focusedTerminal: GhosttyTerminalView? {
        tabManager.terminalSurfaceStore.ghosttySurface(for: tab.focusedPaneId)
    }

    private var hasFocusedTerminal: Bool {
        focusedTerminal != nil
    }

    private var showingVoiceRecording: Bool { voiceRecordingOperation.isActive }
    private var voiceProcessing: Bool { voiceRecordingOperation.isProcessing }

    /// Split actions for menu commands - only active when this tab is selected
    private var splitActions: TerminalSplitActions? {
        guard isSelected else { return nil }
        return TerminalSplitActions(
            perform: handleSplitCommand,
            isEnabled: { tabManager.canPerformSplitCommand($0, in: tab) },
            isZoomed: { tabManager.isSplitZoomed(in: tab) }
        )
    }

    @ViewBuilder
    private func withTerminalKeyboardAvoidance<Content: View>(_ content: Content) -> some View {
        #if os(iOS)
        content.terminalKeyboardAvoidance(
            focusedPaneId: isSelected ? tab.focusedPaneId : nil,
            paneIds: tab.allPaneIds,
            terminalSurfaceChange: tabManager.terminalSurfaceStore.latestChange,
            terminalProvider: { tabManager.terminalSurfaceStore.ghosttySurface(for: $0) },
            keyboardCoordinator: tabManager.keyboardCoordinator
        )
        #else
        content.terminalKeyboardAvoidance(
            focusedPaneId: isSelected ? tab.focusedPaneId : nil,
            paneIds: tab.allPaneIds,
            terminalSurfaceChange: tabManager.terminalSurfaceStore.latestChange,
            terminalProvider: { tabManager.terminalSurfaceStore.ghosttySurface(for: $0) }
        )
        #endif
    }

    var body: some View {
        withTerminalKeyboardAvoidance(ZStack {
            // Refresh when terminals register/unregister so overlays can update immediately.
            let _ = tabManager.terminalSurfaceStore.latestChange
            if tabManager.isSplitZoomed(in: tab), tab.hasSplits {
                renderPane(tab.focusedPaneId)
            } else if let layout = tab.layout {
                renderNode(layout)
            } else {
                renderPane(tab.rootPaneId)
            }

            if shouldShowVoiceOverlay {
                platformVoiceOverlay
            }
        }
        .terminalCommandFocusValues(
            activeServerId: isSelected ? server.id : nil,
            activePaneId: isSelected ? tab.focusedPaneId : nil,
            splitActions: splitActions
        )
        )
        .terminalCloseConfirmationAlert(
            isPresented: $showingCloseConfirmation,
            message: String(localized: "The remote connection will be terminated."),
            onClose: closeCurrentPane
        )
        .alert("Voice Input Unavailable", isPresented: $showingPermissionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(permissionErrorMessage)
        }
        .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
        .onAppear {
            updateKeyMonitor()
        }
        .onChange(of: isSelected) { _ in
            updateKeyMonitor()
            if !isSelected {
                cancelVoiceRecording()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                cancelVoiceRecording()
            }
        }
        .onChange(of: showingVoiceRecording) { isRecording in
            publishVoiceRecordingState(isRecording)
        }
        .onChange(of: tab.focusedPaneId) { _ in
            if showingVoiceRecording {
                publishVoiceRecordingState(true)
            }
        }
        .onDisappear {
            cleanupKeyMonitor()
            cancelVoiceRecording()
            publishVoiceRecordingState(false)
        }
    }

    private func requestClosePane() {
        #if os(iOS)
        tabManager.keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
        #endif
        showingCloseConfirmation = true
    }

    // MARK: - Render Split Tree

    private func renderNode(_ node: TerminalSplitNode) -> AnyView {
        switch node {
        case .leaf(let paneId):
            return renderPane(paneId)

        case .split(let split):
            let currentNode = node
            let ratioBinding = Binding<CGFloat>(
                get: { CGFloat(split.ratio) },
                set: { newRatio in
                    updateRatio(node: currentNode, newRatio: Double(newRatio))
                }
            )

            return AnyView(
                SplitView(
                    split.direction == .horizontal ? .horizontal : .vertical,
                    ratioBinding,
                    dividerColor: dividerColor,
                    left: { renderNode(split.left) },
                    right: { renderNode(split.right) },
                    onEqualize: { equalizeLayout() }
                )
            )
        }
    }

    private func renderPane(_ paneId: UUID) -> AnyView {
        AnyView(
            TerminalPaneView(
                paneId: paneId,
                server: server,
                tabManager: tabManager,
                securityActions: securityActions,
                isFocused: tab.focusedPaneId == paneId,
                isTabSelected: isSelected,
                onFocus: { focusPane(paneId) },
                onProcessExit: { handlePaneExit(paneId: paneId) },
                terminalContextMenuActions: terminalContextMenuActions(for: paneId),
                onPaneKeyboardShortcut: handleSplitCommand,
                appearance: appearance,
                showsVoiceButton: isSelected
                    && voiceSettingsStore.settings.terminalVoiceButtonEnabled
                    && !showingVoiceRecording
                    && tab.focusedPaneId == paneId
                    && hasFocusedTerminal,
                onVoiceTrigger: { startVoiceRecording() }
            )
            .id("\(paneId)-\(layoutVersion)")
        )
    }

    // MARK: - Actions

    private func focusPane(_ paneId: UUID) {
        tabManager.focusPane(in: tab, paneId: paneId)
    }

    private func updateRatio(node: TerminalSplitNode, newRatio: Double) {
        tabManager.updateSplitRatio(in: tab, node: node, ratio: newRatio)
    }

    private func equalizeLayout() {
        tabManager.equalizeSplitLayout(in: tab)
    }

    private func handlePaneExit(paneId: UUID) {
        let startToken = tabManager.transportCoordinator.connectionOwnershipToken(for: paneId)
        tabManager.updatePaneState(paneId, connectionState: .disconnected)
        guard let startToken else { return }
        Task {
            await tabManager.transportCoordinator.unregisterSSHClient(
                for: paneId,
                ifOwnedBy: startToken
            )
        }
    }

    // MARK: - Split Actions

    private func splitPane(_ paneId: UUID, placement: TerminalSplitPlacement) {
        guard storeManager.isPro else {
            showingSplitPaneUpgradeAlert = true
            return
        }
        focusPane(paneId)
        let newPaneId: UUID?
        switch placement {
        case .right:
            newPaneId = tabManager.splitRight(
                tab: tab,
                paneId: paneId,
                hasProAccess: storeManager.isPro
            )
        case .left:
            newPaneId = tabManager.splitLeft(
                tab: tab,
                paneId: paneId,
                hasProAccess: storeManager.isPro
            )
        case .down:
            newPaneId = tabManager.splitDown(
                tab: tab,
                paneId: paneId,
                hasProAccess: storeManager.isPro
            )
        case .up:
            newPaneId = tabManager.splitUp(
                tab: tab,
                paneId: paneId,
                hasProAccess: storeManager.isPro
            )
        }
        guard newPaneId != nil else { return }
        layoutVersion += 1
    }

    private func terminalContextMenuActions(for paneId: UUID) -> TerminalContextMenuActions {
        TerminalContextMenuActions(
            focus: { focusPane(paneId) },
            splitRight: { splitPane(paneId, placement: .right) },
            splitLeft: { splitPane(paneId, placement: .left) },
            splitDown: { splitPane(paneId, placement: .down) },
            splitUp: { splitPane(paneId, placement: .up) },
            currentTitle: {
                tabManager.displayTitle(forPane: paneId, fallback: tab.title) ?? tab.title
            },
            setTitle: { title in
                tabManager.setPaneTitleOverride(title, for: paneId)
            }
        )
    }

    func closeCurrentPane() {
        tabManager.closePane(tab: tab, paneId: tab.focusedPaneId)
    }

    private func handleSplitCommand(_ command: TerminalSplitCommand) {
        switch tabManager.performSplitCommand(
            command,
            in: tab,
            hasProAccess: storeManager.isPro
        ) {
        case .performed:
            if command.createsPane {
                layoutVersion += 1
            }
        case .requiresUpgrade:
            showingSplitPaneUpgradeAlert = true
        case .requiresCloseConfirmation:
            requestClosePane()
        case .unavailable:
            break
        }
    }

    // MARK: - Voice Input

    private var voiceOverlay: some View {
        VoiceRecordingView(
            audioService: audioService,
            onStop: { finishVoiceRecording() },
            onCancel: {
                cancelVoiceRecording()
            },
            isProcessing: voiceProcessing
        )
    }

    private var shouldShowVoiceOverlay: Bool {
        guard isSelected, hasFocusedTerminal, showingVoiceRecording else { return false }
        #if os(iOS)
        return tabManager.sessionState
            .paneState(for: tab.focusedPaneId)?.connectionState.isConnected == true
        #else
        return true
        #endif
    }

    private var platformVoiceOverlay: some View {
        #if os(iOS)
        voiceOverlay
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 16)
            .padding(.bottom, 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(1)
        #else
        voiceOverlay
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        #endif
    }

    #if os(macOS)
    private func updateKeyMonitor() {
        if isSelected {
            setupKeyMonitor()
        } else {
            cleanupKeyMonitor()
        }
    }

    private func setupKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            handleMonitoredKeyDown(event)
        }
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleMonitoredKeyDown(_ event: NSEvent) -> NSEvent? {
        handleVoiceShortcut(event)
    }

    private func handleVoiceShortcut(_ event: NSEvent) -> NSEvent? {
        guard isSelected else { return event }

        let keyCodeEscape: UInt16 = 53
        let keyCodeReturn: UInt16 = 36

        if showingVoiceRecording {
            if event.keyCode == keyCodeEscape {
                cancelVoiceRecording()
                return nil
            }
            if event.keyCode == keyCodeReturn {
                toggleVoiceRecording()
                return nil
            }
        }

        guard MacTerminalShortcut.toggleVoiceRecording.matches(event) else {
            return event
        }
        toggleVoiceRecording()
        return nil
    }
    #else
    private func updateKeyMonitor() {}
    private func cleanupKeyMonitor() {}
    #endif

    private func toggleVoiceRecording() {
        if showingVoiceRecording {
            finishVoiceRecording()
        } else {
            startVoiceRecording()
        }
    }

    private func startVoiceRecording() {
        clearPendingVoiceReturnForFocusedPane()
        audioService.cancelRecording()
        #if os(iOS)
        let terminal = focusedTerminal
        let lifecycleState: @MainActor @Sendable () -> AudioCaptureLifecycleState = { [weak terminal] in
            AudioCaptureLifecycleState(
                applicationIsActive: UIApplication.shared.applicationState == .active,
                sceneIsActive: terminal?.window?.windowScene?.activationState == .foregroundActive
            )
        }
        #else
        let lifecycleState: @MainActor @Sendable () -> AudioCaptureLifecycleState = {
            AudioCaptureLifecycleState(
                applicationIsActive: NSApplication.shared.isActive,
                sceneIsActive: NSApplication.shared.isActive
            )
        }
        #endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            startVoiceRecordingOperation(lifecycleState: lifecycleState)
        }
    }

    private func startVoiceRecordingOperation(
        lifecycleState: @escaping @MainActor @Sendable () -> AudioCaptureLifecycleState
    ) {
        voiceRecordingOperation.startRecording(
            operation: { [audioService] operationID in
                try await audioService.startRecording(
                    operationID: operationID,
                    lifecycleState: lifecycleState
                )
            },
            onStarted: {},
            onFailure: { error in
                if let recordingError = error as? AudioService.RecordingError {
                    permissionErrorMessage = recordingError.localizedDescription
                } else {
                    permissionErrorMessage = error.localizedDescription
                }
                showingPermissionError = true
            }
        )
    }

    private func cancelVoiceRecording() {
        voiceRecordingOperation.cancel()
        audioService.cancelRecording()
    }

    private func finishVoiceRecording() {
        guard !voiceProcessing else { return }
        voiceRecordingOperation.startProcessing(
            operation: { [audioService] operationID in
                await audioService.stopRecording(operationID: operationID)
            },
            onSuccess: { text in
                let fallback = text.isEmpty ? audioService.partialTranscription : text
                sendTranscriptionToTerminal(fallback)
            },
            onFailure: { _ in }
        )
    }

    private func sendTranscriptionToTerminal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let terminal = focusedTerminal else { return }
        let paneId = tab.focusedPaneId
        #if os(iOS)
        let shouldShowReturnControl = tabManager.keyboardCoordinator.isUserHidden
        #endif
        terminal.sendText(trimmed)
        #if os(iOS)
        if shouldShowReturnControl {
            tabManager.applyTerminalVoiceEvent(.transcriptionSent, for: paneId)
        }
        #endif
    }

    private func publishVoiceRecordingState(_ isRecording: Bool) {
        #if os(iOS)
        for paneId in tab.allPaneIds where !isRecording || paneId != tab.focusedPaneId {
            tabManager.applyTerminalVoiceEvent(.recordingStopped, for: paneId)
        }
        if isRecording {
            tabManager.applyTerminalVoiceEvent(.recordingStarted, for: tab.focusedPaneId)
        }
        #endif
    }

    private func clearPendingVoiceReturnForFocusedPane() {
        #if os(iOS)
        tabManager.applyTerminalVoiceEvent(.pendingReturnDismissed, for: tab.focusedPaneId)
        #endif
    }
}

// MARK: - Terminal Pane View

/// Renders a single terminal pane (leaf in split tree)
struct TerminalPaneView: View {
    let paneId: UUID
    let server: Server
    @ObservedObject var tabManager: TerminalTabManager
    let securityActions: TerminalSecurityActions
    let isFocused: Bool
    let isTabSelected: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let terminalContextMenuActions: TerminalContextMenuActions
    let onPaneKeyboardShortcut: (TerminalSplitCommand) -> Void
    let appearance: TerminalAppearanceSnapshot
    let showsVoiceButton: Bool
    let onVoiceTrigger: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @EnvironmentObject private var appLockManager: AppLockManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var isReady = false
    @State private var credentials: ServerCredentials?
    @State private var credentialLoadErrorMessage: String?
    @State private var showingTmuxInstallPrompt = false
    @State private var showingMoshInstallPrompt = false
    @State private var isInstallingMosh = false
    @State private var operationNotice: NoticeItem?
    @State private var dismissFallbackBanner = false
    @StateObject private var connectWatchdog = TerminalConnectionWatchdog()
    @State private var securityApprovalRequest: TerminalSecurityApprovalRequest?
    @StateObject private var richPasteUI = TerminalRichPasteUIModel()
    @ObservedObject private var networkMonitor: NetworkMonitor = .shared

    @AppStorage(TerminalDefaults.sshAutoReconnectKey) private var autoReconnectEnabled = true

    private var paneState: TerminalPaneState? {
        tabManager.sessionState.paneState(for: paneId)
    }

    private var connectionState: ConnectionState {
        paneState?.connectionState ?? .idle
    }

    private var reconnectInFlight: Bool {
        reconnectAttempt != nil
    }

    private var reconnectAttempt: TerminalReconnectCoordinator.Attempt? {
        tabManager.reconnectCoordinator.attempt(for: paneId)
    }

    private var connectionGeneration: UUID {
        tabManager.reconnectCoordinator.connectionGeneration(for: paneId)
    }

    private var credentialBinding: ServerCredentialBinding {
        ServerCredentialBinding(server: server)
    }

    private var showingSecurityApproval: Binding<Bool> {
        Binding(
            get: { securityApprovalRequest != nil },
            set: { isPresented in
                if !isPresented {
                    securityApprovalRequest = nil
                }
            }
        )
    }

    /// Should this pane actually have focus (both tab selected AND pane focused)
    private var shouldFocus: Bool {
        isTabSelected && isFocused
    }

    /// Check if terminal already exists (reuse case)
    private var terminalExists: Bool {
        tabManager.terminalSurfaceStore.surface(for: paneId) != nil
    }

    private var fallbackBannerMessage: String? {
        guard paneState?.activeTransport == .sshFallback else { return nil }
        guard !dismissFallbackBanner else { return nil }
        return paneState?.moshFallbackReason?.bannerMessage ?? String(localized: "Using SSH fallback for this session.")
    }

    private var shouldPromptMoshInstall: Bool {
        guard server.connectionMode == .mosh else { return false }
        guard paneState?.activeTransport == .sshFallback else { return false }
        return paneState?.moshFallbackReason?.shouldOfferServerMaintenance == true
    }

    private var moshServerPromptTitle: String {
        paneState?.moshFallbackReason == .serverRuntimeBroken
            ? String(localized: "Repair mosh-server?")
            : String(localized: "Install mosh-server?")
    }

    private var moshServerPromptAction: String {
        paneState?.moshFallbackReason == .serverRuntimeBroken
            ? String(localized: "Repair")
            : String(localized: "Install")
    }

    private var moshServerPromptMessage: String {
        paneState?.moshFallbackReason == .serverRuntimeBroken
            ? String(localized: "Mosh is selected, but the installed mosh-server cannot run. Repair its package installation and reconnect?")
            : String(localized: "Mosh is selected for this server, but mosh-server is missing on the host.")
    }

    private var shouldShowMoshDurabilityHint: Bool {
        guard server.connectionMode == .mosh else { return false }
        return paneState?.tmuxStatus == .off
    }

    private var shouldUseReconnectBannerPresentation: Bool {
        TerminalConnectionPresentationPolicy.usesReconnectBanner(
            connectionState: connectionState,
            hasEstablishedConnection: paneState?.hasEstablishedConnection == true,
            automaticReconnectAllowed: automaticReconnectAllowed,
            isReconnectPreparationInFlight: reconnectInFlight
        )
    }

    private var automaticReconnectAllowed: Bool {
        guard autoReconnectEnabled else { return false }
        if case .failed = connectionState {
            return paneState?.disconnectReason?.allowsAutomaticReconnect == true
        }
        return paneState?.disconnectReason?.allowsAutomaticReconnect ?? true
    }

    private var isAwaitingTmuxSelection: Bool {
        tabManager.tmuxCoordinator.attachPrompt?.paneId == paneId
    }

    private var noticeSurfaceStyle: NoticeSurfaceStyle {
        .terminal(
            backgroundColor: Color.fromHex(appearance.activeTheme.palette.backgroundHex),
            foregroundColor: Color.fromHex(appearance.activeTheme.palette.foregroundHex)
        )
    }

    private var disconnectedStatusMessage: String? {
        if let message = paneState?.disconnectReason?.statusMessage {
            return message
        }

        if paneState?.tmuxStatus.indicatesTmux == true {
            return String(localized: "tmux session is still running on the server.")
        }

        if shouldShowMoshDurabilityHint {
            return String(localized: "Without tmux, app backgrounding can interrupt running commands.")
        }

        return nil
    }

    private var connectionStatusPresentation: TerminalConnectionStatusPresentation {
        .resolve(
            credentialLoadErrorMessage: credentialLoadErrorMessage,
            connectionState: connectionState,
            serverName: server.name,
            hasEstablishedConnection: paneState?.hasEstablishedConnection == true,
            automaticReconnectAllowed: automaticReconnectAllowed,
            isReconnectPreparationInFlight: reconnectInFlight,
            isAwaitingTmuxSelection: isAwaitingTmuxSelection,
            terminalExists: terminalExists,
            isReady: isReady,
            disconnectedMessage: disconnectedStatusMessage
        )
    }

    private var reconnectBannerMessage: String? {
        guard shouldUseReconnectBannerPresentation else { return nil }

        if reconnectAttempt?.phase == .waitingForNetwork {
            return String(localized: "Waiting for network…")
        }

        if case .reconnecting(let attempt) = connectionState {
            return String(format: String(localized: "Reconnecting (attempt %lld)…"), Int64(attempt))
        }

        return String(localized: "Reconnecting…")
    }

    private var topBannerNotice: NoticeItem? {
        if let reconnectBannerMessage {
            return NoticeItem(
                id: "pane-reconnect-\(paneId.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .activity,
                message: reconnectBannerMessage
            )
        }

        if let fallbackBannerMessage {
            return NoticeItem(
                id: "pane-fallback-\(paneId.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .icon("arrow.trianglehead.2.clockwise"),
                message: fallbackBannerMessage,
                detail: paneState?.moshFallbackDiagnostics?.copyText,
                dismissAction: { dismissFallbackBanner = true }
            )
        }

        return richPasteUI.topBannerNotice
    }

    private var bottomOperationNotice: NoticeItem? {
        if paneState?.tmuxStatus == .installing {
            return NoticeItem(
                id: "pane-tmux-install-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing tmux"),
                message: String(localized: "Preparing persistent shell support.")
            )
        }

        if isInstallingMosh {
            return NoticeItem(
                id: "pane-mosh-install-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing mosh-server"),
                message: String(localized: "Preparing the remote host for Mosh.")
            )
        }

        if let operationNotice {
            return operationNotice
        }

        return richPasteUI.bottomOperationNotice
    }

    private var voiceTriggerBottomInset: CGFloat {
        bottomOperationNotice == nil ? 0 : 104
    }

    var body: some View {
        NoticeHost(
            topBanner: topBannerNotice,
            bottomOperation: bottomOperationNotice,
            bannerSurfaceStyle: noticeSurfaceStyle,
            operationSurfaceStyle: noticeSurfaceStyle
        ) {
            ZStack {
                Color.fromHex(appearance.activeTheme.palette.backgroundHex)

                if ghosttyApp.readiness == .ready, let credentials = credentials {
                    terminalSurface(credentials: credentials)
                }

                TerminalConnectionStatusView(
                    presentation: connectionStatusPresentation,
                    connectionAttemptID: connectWatchdog.token,
                    surfaceStyle: noticeSurfaceStyle,
                    isActive: shouldFocus,
                    onRetry: retryConnection,
                    onTrustNewHostKey: presentHostKeyTrustConfirmation
                )

                if shouldShowFloatingVoiceButton {
                    voiceTriggerButton
                        .padding(.bottom, voiceTriggerBottomInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity)
                }
            }
        }
        .opacity(isFocused ? 1.0 : 0.7)
        .clipped()
        .task {
            ghosttyApp.startIfNeeded(appearance: appearance)
            // If terminal exists, mark ready immediately
            if terminalExists {
                isReady = true
            }
            loadCredentials()

            showingTmuxInstallPrompt = TmuxInstallPromptPolicy.shouldPresent(
                for: paneState?.tmuxStatus
            )
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
            startConnectWatchdog()
            reconcileAutomaticReconnect()
        }
        .onChange(of: scenePhase) { _ in
            reconcileAutomaticReconnect()
        }
        .onChange(of: networkMonitor.readiness) { readiness in
            if readiness == .ready {
                tabManager.transportCoordinator.notifyEternalTerminalNetworkPathChanged(for: paneId)
            }
            reconcileAutomaticReconnect()
        }
        .onChange(of: autoReconnectEnabled) { _ in
            reconcileAutomaticReconnect()
        }
        .onChange(of: isReady) { _ in
            startConnectWatchdog()
        }
        .onChange(of: connectionState) { state in
            if state.isConnecting || state.isConnected {
                tabManager.reconnectCoordinator.cancelAutomaticRetry(for: paneId)
                startConnectWatchdog()
            } else if case .disconnected = state {
                connectWatchdog.cancel()
                reconcileAutomaticReconnect()
            } else if case .failed = state {
                connectWatchdog.cancel()
            }
        }
        .onChange(of: connectionGeneration) { _ in
            isReady = false
            startConnectWatchdog()
        }
        .onChange(of: credentialBinding) { _ in
            credentials = nil
            loadCredentials()
        }
        .onChange(of: paneState?.tmuxStatus) { status in
            showingTmuxInstallPrompt = TmuxInstallPromptPolicy.shouldPresent(for: status)
        }
        .onChange(of: isAwaitingTmuxSelection) { isAwaitingSelection in
            if !isAwaitingSelection {
                startConnectWatchdog()
            } else {
                connectWatchdog.cancel()
            }
        }
        .onChange(of: paneState?.moshFallbackReason) { _ in
            if paneState?.activeTransport == .sshFallback {
                dismissFallbackBanner = false
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .onChange(of: paneState?.activeTransport) { transport in
            dismissFallbackBanner = transport != .sshFallback ? false : dismissFallbackBanner
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .task(id: paneState?.activeTransport == .sshFallback ? paneState?.moshFallbackReason : nil) {
            guard paneState?.activeTransport == .sshFallback else { return }
            dismissFallbackBanner = false
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissFallbackBanner = true
        }
        .onDisappear {
            tabManager.reconnectCoordinator.removeAutomaticReconnectContext(for: paneId)
            connectWatchdog.cancel()
        }
        .alert("Install tmux?", isPresented: $showingTmuxInstallPrompt) {
            Button("Install") {
                Task {
                    await tabManager.tmuxCoordinator.startInstall(for: paneId) {
                        retryConnection()
                    }
                }
            }
            Button("Continue without persistence", role: .cancel) {
                disableTmuxForServer()
            }
        } message: {
            Text("tmux keeps your terminal session alive across app restarts and disconnects.")
        }
        .alert(moshServerPromptTitle, isPresented: $showingMoshInstallPrompt) {
            Button(moshServerPromptAction) {
                Task {
                    await installMoshServerAndReconnect()
                }
            }
            Button("Continue with SSH", role: .cancel) {}
        } message: {
            Text(moshServerPromptMessage)
        }
        .alert(
            securityApprovalTitle,
            isPresented: showingSecurityApproval,
            presenting: securityApprovalRequest
        ) { request in
            securityApprovalActions(for: request)
        } message: { request in
            Text(securityApprovalMessage(for: request))
        }
        .terminalRichPastePrompt(using: richPasteUI)
    }

    private var shouldShowFloatingVoiceButton: Bool {
        #if os(macOS)
        showsVoiceButton && isFocused && isTabSelected && connectionState.isConnected
        #else
        false
        #endif
    }

    @ViewBuilder
    private func terminalSurface(credentials: ServerCredentials) -> some View {
        #if os(iOS)
        RemoteTerminalPaneWrapper(
            paneId: paneId,
            server: server,
            credentials: credentials,
            tabManager: tabManager,
            richPasteUIModel: richPasteUI,
            isActive: shouldFocus,
            terminalContextMenuActions: terminalContextMenuActions,
            onPaneKeyboardShortcut: onPaneKeyboardShortcut,
            onProcessExit: onProcessExit,
            onReady: { isReady = true },
            onVoiceTrigger: voiceTriggerHandlerForTerminal,
            onSceneActivation: reconcileAutomaticReconnect
        )
        .id(connectionGeneration)
        .allowsHitTesting(connectionState.isConnected)
        #else
        RemoteTerminalPaneWrapper(
            paneId: paneId,
            server: server,
            credentials: credentials,
            tabManager: tabManager,
            richPasteUIModel: richPasteUI,
            isActive: shouldFocus,
            terminalContextMenuActions: terminalContextMenuActions,
            onProcessExit: onProcessExit,
            onReady: { isReady = true }
        )
        .id(connectionGeneration)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        #endif
    }

    private var voiceTriggerHandlerForTerminal: (() -> Void)? {
        #if os(iOS)
        guard showsVoiceButton else { return nil }
        return {
            guard connectionState.isConnected, isReady else { return }
            onVoiceTrigger()
        }
        #else
        guard showsVoiceButton, connectionState.isConnected, isReady else { return nil }
        return onVoiceTrigger
        #endif
    }

    private func disableTmuxForServer() {
        tabManager.tmuxCoordinator.disable(for: server.id)
    }

    private func presentHostKeyTrustConfirmation() {
        securityApprovalRequest = securityActions.pendingHostKeyApproval(server)
    }

    private var securityApprovalTitle: String {
        guard let securityApprovalRequest else { return "" }
        switch securityApprovalRequest {
        case .credentialEndpoint:
            return String(localized: "Approve Credential Endpoint?")
        case .hostKey(let challenge):
            return SSHHostKeyTrustPresentation(challenge: challenge).title
        }
    }

    private func securityApprovalMessage(
        for request: TerminalSecurityApprovalRequest
    ) -> String {
        switch request {
        case .credentialEndpoint:
            credentialEndpointApprovalMessage
        case .hostKey(let challenge):
            SSHHostKeyTrustPresentation(challenge: challenge).message
        }
    }

    @ViewBuilder
    private func securityApprovalActions(
        for request: TerminalSecurityApprovalRequest
    ) -> some View {
        switch request {
        case .credentialEndpoint:
            Button("Cancel", role: .cancel) {}
            Button("Approve") {
                approveCredentialEndpoint(request)
            }
        case .hostKey(let challenge):
            let presentation = SSHHostKeyTrustPresentation(challenge: challenge)
            Button("Cancel", role: .cancel) {
                rejectHostKeyChallenge(request)
            }
            if presentation.isDestructive {
                Button(presentation.approvalButtonTitle, role: .destructive) {
                    approveHostKeyChallengeAndRetry(request)
                }
            } else {
                Button(presentation.approvalButtonTitle) {
                    approveHostKeyChallengeAndRetry(request)
                }
            }
        }
    }

    private func rejectHostKeyChallenge(_ request: TerminalSecurityApprovalRequest) {
        securityActions.reject(request)
        if securityApprovalRequest == request {
            securityApprovalRequest = nil
        }
    }

    private func approveHostKeyChallengeAndRetry(
        _ request: TerminalSecurityApprovalRequest
    ) {
        switch securityActions.approve(request, server) {
        case .approved:
            if securityApprovalRequest == request {
                securityApprovalRequest = nil
            }
            retryConnection()
        case .failed:
            credentialLoadErrorMessage = String(
                localized: "SSH host key approval expired. Try again."
            )
            if securityApprovalRequest == request {
                securityApprovalRequest = nil
            }
        }
    }

    private var credentialEndpointApprovalMessage: String {
        String(
            format: String(localized: "Stored credentials were saved for another endpoint. Use them with %@:%lld only if you trust this change."),
            server.host,
            Int64(server.port)
        )
    }

    private func loadCredentials() {
        do {
            credentials = try securityActions.loadCredentials(server)
            credentialLoadErrorMessage = nil
        } catch ServerCredentialAccessError.approvalRequired {
            credentials = nil
            credentialLoadErrorMessage = String(localized: "Credential endpoint approval is required")
            securityApprovalRequest = .credentialEndpoint(serverID: server.id)
        } catch {
            credentials = nil
            credentialLoadErrorMessage = String(localized: "Failed to load credentials")
        }
    }

    private func approveCredentialEndpoint(_ request: TerminalSecurityApprovalRequest) {
        Task {
            guard await appLockManager.authorizeProtectedServerAction(
                server,
                action: .approveCredentialEndpoint
            ) else { return }
            guard securityApprovalRequest == nil
                    || securityApprovalRequest == request else { return }

            switch securityActions.approve(request, server) {
            case .approved:
                loadCredentials()
            case .failed:
                credentialLoadErrorMessage = String(localized: "Failed to approve credentials")
            }
        }
    }

    private func reconcileAutomaticReconnect() {
        #if os(iOS)
        let applicationIsActive = UIApplication.shared.applicationState == .active
        #else
        let applicationIsActive = NSApplication.shared.isActive
        #endif
        tabManager.reconnectCoordinator.reconcileAutomaticReconnect(
            for: paneId,
            sceneIsActive: foregroundSceneIsActive,
            applicationIsActive: applicationIsActive,
            automaticReconnectAllowed: automaticReconnectAllowed
        )
    }

    private func retryConnection() {
        retryConnection(requiresReadyNetwork: false)
    }

    private func retryConnection(requiresReadyNetwork: Bool) {
        tabManager.reconnectCoordinator.cancelAutomaticRetry(for: paneId)
        guard !requiresReadyNetwork || networkMonitor.readiness == .ready else { return }
        guard reconnectAttempt == nil else { return }
        guard !connectionState.isConnecting else { return }
        connectWatchdog.cancel()
        credentialLoadErrorMessage = nil
        operationNotice = nil
        if credentials?.isAuthorized(for: server) != true {
            credentials = nil
            loadCredentials()
            guard credentials != nil else { return }
        }
        tabManager.clearMoshFallbackDiagnostics(for: paneId)
        _ = tabManager.reconnectCoordinator.request(
            for: paneId,
            requiresReadyNetwork: requiresReadyNetwork
        )
    }

    private var foregroundSceneIsActive: Bool {
        #if os(iOS)
        let windowSceneIsActive = tabManager.terminalSurfaceStore
            .surface(for: paneId)?
            .isHostingSceneActive
        return TerminalSceneActivityPolicy.isActive(
            environmentIsActive: scenePhase == .active,
            windowSceneIsActive: windowSceneIsActive
        )
        #else
        return scenePhase == .active
        #endif
    }

    private func startConnectWatchdog() {
        guard TerminalConnectionWatchdogPolicy.shouldMonitor(
            connectionState: connectionState,
            isReady: isReady,
            terminalExists: terminalExists,
            isAwaitingUserSelection: isAwaitingTmuxSelection
        ) else {
            connectWatchdog.cancel()
            return
        }
        connectWatchdog.replace {
            guard !isAwaitingTmuxSelection else { return }
            let stillConnecting = connectionState.isConnecting
            let stillConnectedWithoutTerminal = connectionState.isConnected && !isReady && !terminalExists
            guard stillConnecting || stillConnectedWithoutTerminal else { return }

            if stillConnectedWithoutTerminal {
                tabManager.updatePaneState(paneId, connectionState: .disconnected)
                retryConnection()
                return
            }

            if tabManager.transportCoordinator.hasLiveTransport(for: paneId), connectionState.isConnected {
                tabManager.updatePaneState(paneId, connectionState: .connected)
                return
            }

            let inFlight = tabManager.transportCoordinator.isTransportStartInFlight(for: paneId)
            if inFlight {
                // Keep polling while a shell start is still in flight so stale locks
                // and hung attempts are eventually surfaced to the user.
                startConnectWatchdog()
                return
            }

            tabManager.updatePaneState(
                paneId,
                connectionState: .failed(.reconnectTimedOut)
            )
        }
    }

    @MainActor
    private func installMoshServerAndReconnect() async {
        guard !isInstallingMosh else { return }
        isInstallingMosh = true
        defer { isInstallingMosh = false }

        do {
            try await tabManager.transportCoordinator.installMoshServer(for: paneId)
            operationNotice = nil
            retryConnection()
        } catch {
            operationNotice = NoticeItem(
                id: "pane-mosh-install-error-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .error,
                leading: .icon("xmark.octagon.fill"),
                title: String(localized: "mosh-server install failed"),
                message: error.localizedDescription,
                dismissAction: { operationNotice = nil }
            )
        }
    }

    private var voiceTriggerButton: some View {
        Button {
            onVoiceTrigger()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Voice input (Command+Shift+M)"))
        .padding(14)
    }
}
