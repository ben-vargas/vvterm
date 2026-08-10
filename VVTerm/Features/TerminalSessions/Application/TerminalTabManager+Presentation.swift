import Foundation

extension TerminalTabManager {
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
