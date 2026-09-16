//
//  SessionConnectionStatus+iOS.swift
//  VVTerm
//

import Foundation

#if os(iOS)
nonisolated enum SessionConnectionStatus: Equatable, Sendable {
    case ended
    case ready
    case loading
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case resumable
    case failed(String)

    init(pane: TerminalPaneState, hasResumeCheckpoint: Bool) {
        switch pane.connectionState {
        case .idle, .disconnected:
            switch pane.disconnectReason {
            case .sessionEnded, .startupActionCompleted, .externalRemoteSessionTerminated:
                self = .ended
            default:
                if hasResumeCheckpoint || pane.remoteSessionStatus == .background
                    || pane.remoteSessionStatus == .foreground {
                    self = .resumable
                } else {
                    self = .ended
                }
            }
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reconnecting(let attempt): self = .reconnecting(attempt: attempt)
        case .failed(let failure):
            self = .failed(TerminalConnectionFailurePresentation.message(for: failure))
        }
    }

    var label: String {
        switch self {
        case .ended: String(localized: "Disconnected")
        case .ready: String(localized: "Ready")
        case .loading: String(localized: "Loading Files")
        case .connecting:
            String(localized: "Connecting...")
        case .connected:
            String(localized: "Connected")
        case .reconnecting(let attempt):
            String(
                format: String(localized: "Reconnecting (%lld)..."),
                Int64(attempt)
            )
        case .resumable:
            String(localized: "Ready to resume")
        case .failed(let message):
            String(format: String(localized: "Failed: %@"), message)
        }
    }
}

#endif
