import Foundation

enum SSHError: LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case tailscaleAuthenticationNotAccepted
    case cloudflareConfigurationRequired(String)
    case cloudflareAuthenticationFailed(String)
    case cloudflareTunnelFailed(String)
    case moshServerMissing
    case moshServerRuntimeBroken
    case moshBootstrapFailed(String)
    case moshSessionFailed(String)
    case moshInvalidEndpoint
    case moshUDPTimeout
    case moshClientSessionFailed(String)
    case disconnectedBeforeShellRequest
    case startupCommandMayHaveRun
    case timeout
    case channelOpenFailed
    case ptyRequestFailed
    case processRequestDenied
    case processRequestOutcomeUnknown
    case shellRequestFailed
    case managedStartupCommandUnsupported(String)
    case persistentSessionStartupCommandConflict
    case unsupportedRemoteShellForStartupCommand
    case outputLimitExceeded
    case hostKeyApprovalRequired
    case hostKeyVerificationFailed
    case socketError(String)
    case unknown(String)

    var provesStartupCommandWasNotDispatched: Bool {
        switch self {
        case .channelOpenFailed,
             .disconnectedBeforeShellRequest,
             .ptyRequestFailed,
             .processRequestDenied,
             .persistentSessionStartupCommandConflict,
             .unsupportedRemoteShellForStartupCommand:
            return true
        default:
            return false
        }
    }

    var allowsAutomaticReconnectRetry: Bool {
        switch self {
        case .notConnected,
             .connectionFailed,
             .cloudflareTunnelFailed,
             .moshSessionFailed,
             .moshUDPTimeout,
             .moshClientSessionFailed,
             .disconnectedBeforeShellRequest,
             .timeout,
             .channelOpenFailed,
             .ptyRequestFailed,
             .processRequestDenied,
             .shellRequestFailed,
             .socketError:
            return true
        case .authenticationFailed,
             .tailscaleAuthenticationNotAccepted,
             .cloudflareConfigurationRequired,
             .cloudflareAuthenticationFailed,
             .moshServerMissing,
             .moshServerRuntimeBroken,
             .moshBootstrapFailed,
             .moshInvalidEndpoint,
             .startupCommandMayHaveRun,
             .processRequestOutcomeUnknown,
             .managedStartupCommandUnsupported,
             .persistentSessionStartupCommandConflict,
             .hostKeyApprovalRequired,
             .hostKeyVerificationFailed,
             .outputLimitExceeded,
             .unsupportedRemoteShellForStartupCommand,
             .unknown:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .tailscaleAuthenticationNotAccepted:
            return "\(String(localized: "Tailscale SSH authentication was not accepted by the server.")) \(String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback)."))"
        case .cloudflareConfigurationRequired(let message):
            return String(format: String(localized: "Cloudflare configuration error: %@"), message)
        case .cloudflareAuthenticationFailed(let message):
            return String(format: String(localized: "Cloudflare authentication failed: %@"), message)
        case .cloudflareTunnelFailed(let message):
            return String(format: String(localized: "Cloudflare tunnel failed: %@"), message)
        case .moshServerMissing:
            return String(localized: "mosh-server is not installed on the remote host")
        case .moshServerRuntimeBroken:
            return String(localized: "mosh-server is installed but cannot run. Repair its package installation on the remote host.")
        case .moshBootstrapFailed(let msg):
            return "Mosh bootstrap failed: \(msg)"
        case .moshSessionFailed(let msg):
            return "Mosh session failed: \(msg)"
        case .moshInvalidEndpoint:
            return "Mosh server address is invalid"
        case .moshUDPTimeout:
            return "Mosh UDP session timed out"
        case .moshClientSessionFailed(let msg):
            return "Mosh client session failed: \(msg)"
        case .disconnectedBeforeShellRequest:
            return String(localized: "The connection ended before the remote shell request was sent.")
        case .startupCommandMayHaveRun:
            return String(localized: "The startup command may have run. VVTerm did not run it again.")
        case .timeout: return String(localized: "Connection timed out")
        case .channelOpenFailed: return "Failed to open channel"
        case .ptyRequestFailed:
            return String(localized: "The remote server rejected the terminal request.")
        case .processRequestDenied:
            return String(localized: "The remote server rejected the shell command.")
        case .processRequestOutcomeUnknown:
            return String(localized: "The connection ended while starting the shell. The startup command was not run again.")
        case .shellRequestFailed: return "Failed to request shell"
        case .managedStartupCommandUnsupported(let backendName):
            return String(
                format: String(localized: "%@ does not support custom startup commands yet."),
                backendName
            )
        case .persistentSessionStartupCommandConflict:
            return String(
                localized: "Turn off session persistence before starting tmux, zmx, Zellij, Herdr, or psmux in this command."
            )
        case .unsupportedRemoteShellForStartupCommand:
            return String(localized: "VVTerm cannot run the startup command because it could not detect a supported remote shell.")
        case .outputLimitExceeded:
            return String(localized: "The remote command produced too much output.")
        case .hostKeyApprovalRequired:
            return String(localized: "SSH host key approval is required before authentication.")
        case .hostKeyVerificationFailed:
            return "Host key verification failed. The saved SSH host fingerprint does not match the server's current key."
        case .socketError(let msg): return "Socket error: \(msg)"
        case .unknown(let msg): return "Unknown error: \(msg)"
        }
    }
}
