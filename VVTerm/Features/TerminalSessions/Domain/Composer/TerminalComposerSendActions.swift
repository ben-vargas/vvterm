import Foundation

nonisolated struct TerminalComposerSendActions: Codable, Equatable, Sendable {
    // The first action is also the tap action; there is no separate saved selection.
    var actions: [TerminalComposerSendAction]
    static let defaults = Self(actions: [.send, .insert, .queue])

    var isValid: Bool {
        !actions.isEmpty && actions.count <= 32
            && Set(actions.map(\.id)).count == actions.count
            && actions.allSatisfy { !$0.steps.isEmpty && $0.steps.count <= 64 && $0.name.count <= 120
                && $0.steps.allSatisfy(\.isValid)
                && Set($0.steps.map(\.id)).count == $0.steps.count }
    }
}
