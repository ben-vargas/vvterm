import Foundation

enum TerminalAccessoryValidationError: LocalizedError {
    case customActionLimitReached
    case emptyTitle
    case emptyCommandContent
    case customActionNotFound

    var errorDescription: String? {
        switch self {
        case .customActionLimitReached:
            return String(
                format: String(localized: "You can create up to %lld custom actions."),
                Int64(TerminalAccessoryProfile.maxCustomActions)
            )
        case .emptyTitle:
            return String(localized: "Action title cannot be empty.")
        case .emptyCommandContent:
            return String(localized: "Command content cannot be empty.")
        case .customActionNotFound:
            return String(localized: "Action not found.")
        }
    }
}
