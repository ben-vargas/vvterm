import Foundation

nonisolated struct TerminalComposerSendAction: Codable, Equatable, Identifiable, Sendable {
    struct Step: Codable, Equatable, Identifiable, Sendable {
        enum Input: Codable, Equatable, Sendable {
            case insertDraft
            case text(String)
            case key(TerminalAccessoryShortcutKey, TerminalAccessoryShortcutModifiers)
        }

        // Repeated keys need distinct identities while editing and reordering.
        var id = UUID()
        var input: Input

        static func text(_ value: String) -> Self { Self(input: .text(value)) }

        var isValid: Bool {
            switch input {
            case .insertDraft, .key: true
            case .text(let value): !value.isEmpty && value.count <= TerminalAccessoryProfile.maxCommandContentLength
            }
        }

        static var insertDraft: Self { Self(input: .insertDraft) }
        static func key(_ key: TerminalAccessoryShortcutKey, _ modifiers: TerminalAccessoryShortcutModifiers) -> Self {
            Self(input: .key(key, modifiers))
        }
    }

    var id = UUID()
    var name = ""
    var steps: [Step]

    var insertsDraft: Bool { steps.contains { $0.input == .insertDraft } }

    static let send = Self(id: UUID(uuidString: "704D03A6-3602-462F-8DF1-1A7D2A0EE001")!, steps: [.insertDraft, .key(.enter, .none)])
    static let insert = Self(id: UUID(uuidString: "704D03A6-3602-462F-8DF1-1A7D2A0EE002")!, steps: [.insertDraft])
    static let queue = Self(id: UUID(uuidString: "704D03A6-3602-462F-8DF1-1A7D2A0EE003")!, steps: [.insertDraft, .key(.tab, .none)])
}
