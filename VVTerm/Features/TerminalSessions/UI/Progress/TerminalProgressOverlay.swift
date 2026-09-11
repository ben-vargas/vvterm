import SwiftUI

struct TerminalProgressOverlay: View {
    @ObservedObject var store: TerminalProgressStore
    let paneId: UUID

    var body: some View {
        if let progress = store.states[paneId] {
            TerminalProgressBar(progress: progress)
                .accessibilityIdentifier("vvterm.terminal.progress.\(paneId.uuidString)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }
}
