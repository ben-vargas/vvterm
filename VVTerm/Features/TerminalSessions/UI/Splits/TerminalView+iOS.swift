#if os(iOS)
import Combine
import Foundation
import SwiftUI
import UIKit

nonisolated enum TerminalRenderingTransition: Equatable, Sendable {
    case none
    case pause
    case resume
}

nonisolated enum TerminalRenderingPolicy {
    static func transition(
        terminalIsActive: Bool,
        sceneIsActive: Bool,
        renderingIsPaused: Bool
    ) -> TerminalRenderingTransition {
        if terminalIsActive && sceneIsActive {
            return renderingIsPaused ? .resume : .none
        }
        return renderingIsPaused ? .none : .pause
    }
}

/// Wraps a remote connection and Ghostty terminal for a pane on iOS/iPadOS.
struct RemoteTerminalPaneWrapper: View {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let tabManager: TerminalTabManager
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onPaneKeyboardShortcut: (TerminalSplitCommand) -> Void
    let onProcessExit: () -> Void
    let onReady: () -> Void
    let onOpenLink: (URL) -> Void
    let showsVoiceAccessoryButton: Bool
    let onVoiceTrigger: ((TerminalVoicePresentationState.RecordingStyle) -> Void)?
    let onSceneActivation: () -> Void

    let acceptsInput: Bool
    let composerVoice: TerminalComposerVoiceInput?
    @ObservedObject var composer: TerminalComposerStore
    @AppStorage(TerminalInputMode.preferenceKey) private var inputMode = TerminalInputMode.direct
    @AppStorage("terminalAttachmentButtonEnabled") private var attachmentButtonEnabled = true

    @EnvironmentObject private var terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
    @AppStorage("terminalKeyboardDismissButtonEnabled") private var keyboardDismissButtonEnabled = true

    private var terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot {
        TerminalAccessoryInputSnapshot(
            profile: terminalAccessoryPreferencesManager.profile,
            showsDismissKeyboardButton: keyboardDismissButtonEnabled,
            showsAttachmentButton: attachmentButtonEnabled
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                RemoteTerminalPaneRepresentable(
                    paneId: paneId,
                    server: server,
                    credentials: credentials,
                    tabManager: tabManager,
                    size: geometry.size,
                    isActive: isActive,
                    terminalContextMenuActions: terminalContextMenuActions,
                    onPaneKeyboardShortcut: onPaneKeyboardShortcut,
                    onProcessExit: onProcessExit,
                    onReady: onReady,
                    onOpenLink: onOpenLink,
                    terminalAccessoryInputSnapshot: terminalAccessoryInputSnapshot,
                    showsVoiceAccessoryButton: showsVoiceAccessoryButton,
                    onVoiceTrigger: onVoiceTrigger
                )
                .background {
                    TerminalSceneActivationObserver(
                        onSceneActivation: handleSceneActivation
                    )
                    .allowsHitTesting(false)
                }
            }
            if composer.mode == .chat {
                TerminalPaneComposerView(presentationState: tabManager.presentationState, composer: composer, paneID: paneId, isActive: isActive, acceptsInput: acceptsInput, voice: composerVoice)
            }
        }
        .onAppear { composer.setMode(inputMode) }
        .onChange(of: inputMode) { mode in
            if composerVoice?.phase.isActive == true { composerVoice?.cancel() }
            composer.setMode(mode)
        }
        .background {
            TerminalAttachmentPicker(composer: composer) {
                guard composer.mode == .direct,
                      tabManager.keyboardCoordinator.canSubmitComposedInput(for: paneId) else { return }
                tabManager.keyboardCoordinator.userRequestedShow()
            }
        }
        .onChange(of: isActive) { active in
            if !active { composer.attachmentSource = nil }
        }
    }

    private func handleSceneActivation(_ activatedScene: UIScene) {
        // A SwiftUI wrapper can briefly outlive registry ownership. Never let
        // that stale wrapper resume or reconnect a terminal now hosted by
        // another scene.
        guard let terminal = tabManager.terminalSurfaceStore.ghosttySurface(for: paneId),
              let terminalScene = terminal.window?.windowScene,
              terminalScene === activatedScene else { return }

        if TerminalRenderingPolicy.transition(
            terminalIsActive: isActive,
            sceneIsActive: terminalScene.activationState == .foregroundActive,
            renderingIsPaused: terminal.isRenderingPaused
        ) == .resume {
            terminal.resumeRendering()
        }
        onSceneActivation()
    }
}

private struct TerminalSceneActivationObserver: UIViewRepresentable {
    let onSceneActivation: (UIScene) -> Void

    func makeUIView(context: Context) -> TerminalSceneActivationView {
        TerminalSceneActivationView(onSceneActivation: onSceneActivation)
    }

    func updateUIView(_ view: TerminalSceneActivationView, context: Context) {
        view.onSceneActivation = onSceneActivation
    }
}

private final class TerminalSceneActivationView: UIView {
    var onSceneActivation: (UIScene) -> Void

    init(onSceneActivation: @escaping (UIScene) -> Void) {
        self.onSceneActivation = onSceneActivation
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let activatedScene = notification.object as? UIScene,
              activatedScene === window?.windowScene else { return }
        Task { @MainActor [weak self, weak activatedScene] in
            guard let self, let activatedScene,
                  activatedScene === self.window?.windowScene else { return }
            self.onSceneActivation(activatedScene)
        }
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

struct RemoteTerminalPaneRepresentable: UIViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let tabManager: TerminalTabManager
    let size: CGSize
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onPaneKeyboardShortcut: (TerminalSplitCommand) -> Void
    let onProcessExit: () -> Void
    let onReady: () -> Void
    let onOpenLink: (URL) -> Void
    let terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot
    let showsVoiceAccessoryButton: Bool
    let onVoiceTrigger: ((TerminalVoicePresentationState.RecordingStyle) -> Void)?

    @EnvironmentObject var ghosttyApp: GhosttyRuntime
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> TerminalPaneConnectionCoordinator {
        TerminalPaneConnectionCoordinator(
            paneId: paneId,
            server: server,
            credentials: credentials,
            tabManager: tabManager,
            sshFailureOutput: { failure in
                TerminalConnectionFailurePresentation.ansiSSHErrorData(for: failure)
            }
        )
    }

    func makeUIView(context: Context) -> UIView {
        guard let app = ghosttyApp.app else {
            return UIView(frame: .zero)
        }

        let coordinator = context.coordinator

        if let existingTerminal = tabManager.terminalSurfaceStore.ghosttySurface(for: paneId) {
            existingTerminal.panePresentationOwner = coordinator
            coordinator.terminal = existingTerminal
            coordinator.isTerminalReady = true
            coordinator.preservePane = true
            configureExistingTerminal(existingTerminal, coordinator: coordinator)
            existingTerminal.acceptsTerminalInput = isActive

            if existingTerminal.superview != nil {
                existingTerminal.removeFromSuperview()
            }
            if size.width > 0 && size.height > 0 {
                coordinator.lastReportedSize = size
                existingTerminal.frame = CGRect(origin: .zero, size: size)
                existingTerminal.sizeDidChange(size)
            }

            DispatchQueue.main.async {
                guard existingTerminal.panePresentationOwner === coordinator else { return }
                onReady()
                startConnectionIfNeeded(
                    terminal: existingTerminal,
                    coordinator: coordinator,
                    state: tabManager.sessionState.paneState(for: paneId)?.connectionState ?? .idle
                )
            }
            return existingTerminal
        }

        let initialSize = (size.width > 0 && size.height > 0) ? size : CGSize(width: 800, height: 600)
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
            terminalAccessoryInputSnapshot: terminalAccessoryInputSnapshot,
            useCustomIO: true
        )

        terminalView.panePresentationOwner = coordinator
        terminalView.onReady = { [weak coordinator, weak terminalView] in
            guard let coordinator else { return }
            DispatchQueue.main.async {
                guard let terminalView, terminalView.panePresentationOwner === coordinator else { return }
                coordinator.isTerminalReady = true
                onReady()
                startConnectionIfNeeded(
                    terminal: terminalView,
                    coordinator: coordinator,
                    state: tabManager.sessionState.paneState(for: paneId)?.connectionState ?? .idle
                )
            }
        }
        terminalView.onProcessExit = processExitHandler(for: terminalView)
        terminalView.showsVoiceAccessoryButton = showsVoiceAccessoryButton
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.onAttachmentButtonTapped = attachmentAction
        terminalView.onPwdChange = { [paneId] rawDirectory in
            DispatchQueue.main.async {
                tabManager.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
        }
        terminalView.onTitleChange = { [paneId] title in
            tabManager.updatePaneTitle(paneId, rawTitle: title)
        }
        terminalView.onZoomAction = { [paneId] action in
            tabManager.handleTerminalZoom(action, for: paneId)
        }
        terminalView.onPaneKeyboardShortcut = onPaneKeyboardShortcut
        terminalView.terminalContextMenuActions = terminalContextMenuActions
        terminalView.onOpenLink = isActive ? onOpenLink : nil
        terminalView.applyPresentationOverrides(
            tabManager.sessionState.presentationOverrides(for: paneId)
        )

        coordinator.terminal = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        tabManager.registerTerminalSurface(terminalView, for: paneId)

        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToTransport(data)
        }
        terminalView.setupWriteCallback()
        terminalView.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }

        coordinator.lastReportedSize = initialSize
        if size.width > 0 && size.height > 0 {
            terminalView.sizeDidChange(size)
        }
        if !isActive {
            terminalView.pauseRendering()
        }

        return terminalView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let terminalView = uiView as? GhosttyTerminalView,
              terminalView.panePresentationOwner === context.coordinator else { return }

        guard tabManager.sessionState.paneState(for: paneId) != nil else {
            terminalView.acceptsTerminalInput = false
            terminalView.writeCallback = nil
            terminalView.onReady = nil
            terminalView.onProcessExit = nil
            terminalView.onOpenLink = nil
            terminalView.showsVoiceAccessoryButton = false
            terminalView.onVoiceButtonTapped = nil
            terminalView.onAttachmentButtonTapped = nil
            terminalView.onPaneKeyboardShortcut = nil
            return
        }

        let windowScene = terminalView.window?.windowScene
        let windowSceneIsActive = windowScene.map {
            $0.activationState == .foregroundActive
        }
        let sceneIsActive = TerminalSceneActivityPolicy.isActive(
            environmentIsActive: scenePhase == .active,
            windowSceneIsActive: windowSceneIsActive
        )
        let renderingTransition = TerminalRenderingPolicy.transition(
            terminalIsActive: isActive,
            sceneIsActive: sceneIsActive,
            renderingIsPaused: terminalView.isRenderingPaused
        )

        terminalView.acceptsTerminalInput = isActive
        let presentationOverrides = tabManager.sessionState.presentationOverrides(for: paneId)
        if terminalView.surfacePresentationOverrides != presentationOverrides {
            terminalView.applyPresentationOverrides(presentationOverrides)
        }
        terminalView.showsVoiceAccessoryButton = showsVoiceAccessoryButton
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.onAttachmentButtonTapped = attachmentAction
        terminalView.applyTerminalAccessoryInputSnapshot(terminalAccessoryInputSnapshot)
        terminalView.onPaneKeyboardShortcut = onPaneKeyboardShortcut
        terminalView.terminalContextMenuActions = terminalContextMenuActions
        terminalView.onOpenLink = isActive ? onOpenLink : nil
        if size.width > 0, size.height > 0, size != context.coordinator.lastReportedSize {
            context.coordinator.lastReportedSize = size
            terminalView.sizeDidChange(size)
        }

        if context.coordinator.isTerminalReady {
            switch renderingTransition {
            case .resume:
                terminalView.resumeRendering()
            case .pause:
                terminalView.pauseRendering()
            case .none:
                break
            }
        }

        let state = tabManager.sessionState.paneState(for: paneId)?.connectionState ?? .idle
        let shouldStartConnection = TerminalConnectionStartPolicy.shouldStart(
            connectionState: state
        )

        if shouldStartConnection {
            startConnectionIfNeeded(
                terminal: terminalView,
                coordinator: context.coordinator,
                state: state
            )
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let terminalView = uiView as? GhosttyTerminalView else { return }
        // A retained UIView may already belong to the incoming SwiftUI host.
        // Late teardown from the outgoing host must not pause that live pane.
        guard terminalView.panePresentationOwner === coordinator else {
            coordinator.terminal = nil
            return
        }
        terminalView.panePresentationOwner = nil
        terminalView.onOpenLink = nil

        let paneStillExists = coordinator.tabManager.sessionState
            .paneState(for: coordinator.paneId) != nil
        if paneStillExists {
            terminalView.acceptsTerminalInput = false
            terminalView.pauseRendering()
            coordinator.preservePane = true
            return
        }

        coordinator.terminal = nil
        let paneId = coordinator.paneId
        Task { @MainActor in
            coordinator.tabManager.unregisterTerminalSurface(terminalView, for: paneId)
            coordinator.cancelConnection()
        }
    }

    private func configureExistingTerminal(_ terminal: GhosttyTerminalView, coordinator: TerminalPaneConnectionCoordinator) {
        terminal.onProcessExit = processExitHandler(for: terminal)
        terminal.showsVoiceAccessoryButton = showsVoiceAccessoryButton
        terminal.onVoiceButtonTapped = onVoiceTrigger
        terminal.onAttachmentButtonTapped = attachmentAction
        terminal.applyTerminalAccessoryInputSnapshot(terminalAccessoryInputSnapshot)
        terminal.onPwdChange = { [paneId] rawDirectory in
            DispatchQueue.main.async {
                tabManager.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
        }
        terminal.onTitleChange = { [paneId] title in
            tabManager.updatePaneTitle(paneId, rawTitle: title)
        }
        terminal.onZoomAction = { [paneId] action in
            tabManager.handleTerminalZoom(action, for: paneId)
        }
        terminal.onPaneKeyboardShortcut = onPaneKeyboardShortcut
        terminal.terminalContextMenuActions = terminalContextMenuActions
        terminal.onOpenLink = isActive ? onOpenLink : nil
        terminal.applyPresentationOverrides(
            tabManager.sessionState.presentationOverrides(for: paneId)
        )
        terminal.writeCallback = { [weak coordinator] data in
            coordinator?.sendToTransport(data)
        }
        coordinator.installRichPasteInterception(on: terminal)
        terminal.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }
    }

    private var attachmentAction: (TerminalComposerStore.AttachmentSource) -> Void {
        { [weak tabManager] source in
            guard let tabManager else { return }
            let composer = tabManager.richPasteRuntimeStore.runtime(for: paneId, tabManager: tabManager).composer
            guard !composer.isBusy else { return }
            composer.attachmentSource = source
        }
    }

    private func processExitHandler(for terminal: GhosttyTerminalView) -> () -> Void {
        { [weak terminal] in
            guard let terminal,
                  tabManager.terminalSurfaceStore.isRegistered(
                    terminal,
                    for: paneId
                  ) else { return }
            onProcessExit()
        }
    }

    private func startConnectionIfNeeded(
        terminal: GhosttyTerminalView,
        coordinator: TerminalPaneConnectionCoordinator,
        state: ConnectionState
    ) {
        guard tabManager.sessionState.paneState(for: paneId) != nil else { return }
        guard !coordinator.hasLiveConnection else { return }
        guard !coordinator.isConnectionStartInFlight else { return }
        guard tabManager.reconnectCoordinator.applicationActivityIsActive else { return }

        switch state {
        case .connecting, .reconnecting, .connected:
            break
        case .disconnected, .failed, .idle:
            return
        }

        coordinator.startConnection(terminal: terminal)
    }
}
#endif
