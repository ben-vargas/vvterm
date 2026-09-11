//
//  GhosttyProgressState.swift
//  VVTerm
//

import Foundation

enum GhosttyProgressState {
    case remove
    case set
    case error
    case indeterminate
    case pause
    case unknown

    init(cState: ghostty_action_progress_report_state_e) {
        switch cState {
        case GHOSTTY_PROGRESS_STATE_REMOVE: self = .remove
        case GHOSTTY_PROGRESS_STATE_SET: self = .set
        case GHOSTTY_PROGRESS_STATE_ERROR: self = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: self = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: self = .pause
        default: self = .unknown
        }
    }
}

extension GhosttyProgressState {
    /// Validate at the native boundary before values enter product state.
    func progress(value: Int?) -> TerminalProgress? {
        let percent = value.map { min(100, max(0, $0)) }
        switch self {
        case .remove: return .inactive
        case .set: return percent.map(TerminalProgress.determinate) ?? .indeterminate
        case .error: return .error(percent)
        case .indeterminate: return .indeterminate
        case .pause: return .paused(percent)
        case .unknown: return nil
        }
    }
}
