import Foundation

nonisolated extension TerminalComposerSendAction {
    var title: String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? summary : title
    }
    var summary: String { steps.map(\.title).joined(separator: " → ") }
}

nonisolated extension TerminalComposerSendAction.Step {
    var title: String {
        switch input {
        case .insertDraft: String(localized: "Insert draft")
        case .text: String(localized: "Text")
        case .key(let key, let modifiers): modifiers.displayTitle(for: key.title)
        }
    }
}

nonisolated extension TerminalComposerSendAction.Step {
    var detail: String? {
        switch input {
        case .text(let text): text.isEmpty ? nil : text
        case .insertDraft, .key: nil
        }
    }

    var symbol: String {
        switch input {
        case .insertDraft: "text.insert"
        case .text: "text.alignleft"
        case .key: "keyboard"
        }
    }
}
