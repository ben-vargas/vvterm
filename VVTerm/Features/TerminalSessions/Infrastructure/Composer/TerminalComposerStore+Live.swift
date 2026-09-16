import Foundation

@MainActor
extension TerminalComposerStore {
    static func terminalPane(paneId: UUID, tabManager: TerminalTabManager) -> TerminalComposerStore {
        let transfer = RemoteClipboardTransferService(sessionId: paneId)
        return TerminalComposerStore(
            resolveRoute: { [weak tabManager] in
                guard let tabManager,
                      let sshRoute = tabManager.transportCoordinator.activeSSHRoute(for: paneId),
                      let terminal = tabManager.terminalSurfaceStore.surface(for: paneId) else {
                    throw TerminalAttachmentError.unavailable
                }
                let client = sshRoute.client
                let isCurrent: @MainActor () -> Bool = { [weak tabManager, weak terminal] in
                    guard let tabManager, let terminal else { return false }
                    return tabManager.transportCoordinator.activeSSHRoute(for: paneId)?.client === client
                        && tabManager.transportCoordinator.activeSSHRoute(for: paneId)?.shellId == sshRoute.shellId
                        && tabManager.sessionState.paneState(for: paneId)?.connectionState.isConnected == true
                        && tabManager.terminalSurfaceStore.surface(for: paneId) === terminal
                }
                return TerminalAttachmentRoute(
                    isCurrent: isCurrent,
                    upload: { try await transfer.upload($0, using: client) },
                    remove: { uploads in
                        var failure: Error?
                        for upload in uploads {
                            do { try await transfer.delete(upload, using: client) }
                            catch { failure = error }
                        }
                        if let failure { throw failure }
                    }
                )
            },
            submit: { [weak tabManager] text, action in
                guard let tabManager,
                      tabManager.sessionState.paneState(for: paneId)?.connectionState.isConnected == true,
                      let terminal = tabManager.terminalSurfaceStore.surface(for: paneId) else {
                    throw TerminalAttachmentError.unavailable
                }
                #if os(iOS)
                guard tabManager.keyboardCoordinator.canSubmitComposedInput(for: paneId),
                      let ghostty = terminal as? GhosttyTerminalView else {
                    throw TerminalAttachmentError.unavailable
                }
                try ghostty.sendComposedText(text, action: action)
                #else
                terminal.sendText(text)
                #endif
            },
            modeChanged: { [weak tabManager] _ in
                #if os(iOS)
                tabManager?.keyboardCoordinator.composerModeDidChange(for: paneId)
                #endif
            }
        )
    }
}
