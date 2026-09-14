import Foundation

nonisolated enum TerminalAccessoryResolvedItem: Equatable, Sendable {
    case system(TerminalAccessorySystemActionID)
    case custom(TerminalAccessoryCustomAction)
}

nonisolated enum TerminalAccessoryInputSnapshotChange: Equatable, Sendable {
    case none
    case leadingButtons
    case itemsAndLeadingButtons
}

nonisolated struct TerminalAccessoryInputSnapshot: Equatable, Sendable {
    let resolvedItems: [TerminalAccessoryResolvedItem]
    let showsAttachmentButton: Bool
    let showsDismissKeyboardButton: Bool

    init(
        profile: TerminalAccessoryProfile,
        showsDismissKeyboardButton: Bool,
        showsAttachmentButton: Bool = true
    ) {
        var customActionsByID: [UUID: TerminalAccessoryCustomAction] = [:]
        for action in profile.customActions where !action.isDeleted {
            customActionsByID[action.id] = action
        }
        resolvedItems = profile.layout.activeItems.compactMap { item in
            switch item {
            case .system(let actionID):
                return .system(actionID)
            case .custom(let actionID):
                guard let action = customActionsByID[actionID] else { return nil }
                return .custom(action)
            }
        }
        self.showsAttachmentButton = showsAttachmentButton
        self.showsDismissKeyboardButton = showsDismissKeyboardButton
    }

    func change(from current: Self) -> TerminalAccessoryInputSnapshotChange {
        if resolvedItems != current.resolvedItems {
            return .itemsAndLeadingButtons
        }
        if showsDismissKeyboardButton != current.showsDismissKeyboardButton || showsAttachmentButton != current.showsAttachmentButton {
            return .leadingButtons
        }
        return .none
    }
}
