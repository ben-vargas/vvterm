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
                return TerminalAttachmentRoute(
                    upload: { try await transfer.upload($0, using: client) },
                    remove: { uploads in
                        for upload in uploads { await transfer.delete(upload, using: client) }
                    },
                    submit: { [weak tabManager, weak terminal] text, mode in
                        guard let tabManager, let terminal,
                              tabManager.transportCoordinator.activeSSHRoute(for: paneId)?.client === client,
                              tabManager.transportCoordinator.activeSSHRoute(for: paneId)?.shellId == sshRoute.shellId,
                              tabManager.sessionState.paneState(for: paneId)?.connectionState.isConnected == true,
                              tabManager.terminalSurfaceStore.surface(for: paneId) === terminal else {
                            throw TerminalAttachmentError.unavailable
                        }
                        #if os(iOS)
                        guard tabManager.keyboardCoordinator.canSubmitComposedInput(for: paneId),
                              let ghostty = terminal as? GhosttyTerminalView else {
                            throw TerminalAttachmentError.unavailable
                        }
                        try ghostty.sendComposedText(text, mode: mode)
                        #else
                        terminal.sendText(text)
                        #endif
                    }
                )
            },
            modeChanged: { [weak tabManager] _ in
                #if os(iOS)
                tabManager?.keyboardCoordinator.composerModeDidChange(for: paneId)
                #endif
            }
        )
    }
}
