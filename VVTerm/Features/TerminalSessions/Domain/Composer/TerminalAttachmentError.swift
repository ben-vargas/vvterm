import Foundation

nonisolated enum TerminalAttachmentError: LocalizedError {
    case limitExceeded
    case unavailable
    case unreadable

    var errorDescription: String? {
        switch self {
        case .limitExceeded: String(localized: "Choose up to 20 attachments, with a total size of 100 MB or less.")
        case .unavailable: String(localized: "Reconnect and select this terminal before sending attachments.")
        case .unreadable: String(localized: "The attachment could not be read.")
        }
    }
}
