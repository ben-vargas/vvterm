import Foundation

nonisolated enum TerminalClipboardWriteAction: Equatable, Sendable {
    case writeImmediately
    case requestConfirmation
}

nonisolated enum TerminalClipboardWritePolicy {
    static func action(requiresConfirmation: Bool) -> TerminalClipboardWriteAction {
        requiresConfirmation ? .requestConfirmation : .writeImmediately
    }
}
