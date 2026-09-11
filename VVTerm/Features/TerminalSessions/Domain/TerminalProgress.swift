import Foundation

/// Transient state reported by the process in one terminal pane.
nonisolated enum TerminalProgress: Equatable, Sendable {
    case inactive
    case determinate(Int)
    case error(Int?)
    case indeterminate
    case paused(Int?)

    var percent: Int? {
        switch self {
        case .determinate(let value): value
        case .error(let value), .paused(let value): value
        case .inactive, .indeterminate: nil
        }
    }

    /// Ghostty displays an unspecified pause as a full orange line.
    var barPercent: Int? {
        if case .paused(nil) = self { return 100 }
        return percent
    }
}
