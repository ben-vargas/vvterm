import Foundation

extension TerminalTabManager {
    #if os(iOS)
    func terminalVoicePresentation(for paneId: UUID) -> TerminalVoicePresentationState {
        terminalVoicePresentationByPane[paneId] ?? .idle
    }
    #endif

    func displayTitle(forPane paneId: UUID, fallback: String? = nil) -> String? {
        titleStore.displayTitle(forPane: paneId, fallback: fallback)
    }

    func presentationOverrides(for paneId: UUID) -> TerminalPresentationOverrides {
        sessionState.paneState(for: paneId)?.presentationOverrides ?? .empty
    }

    func displayTitle(for tab: TerminalTab) -> String {
        titleStore.displayTitle(for: tab)
    }
}
