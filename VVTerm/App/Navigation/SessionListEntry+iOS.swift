#if os(iOS)
import Foundation

struct SessionListEntry: Identifiable {
    let id: SessionDestination
    let title: String
    let createdAt: Date
    let panes: [Pane]
    let fileStatus: SessionConnectionStatus?
    let path: String?

    struct Pane: Identifiable {
        let id: UUID
        let title: String
        let status: SessionConnectionStatus
        let transport: ShellTransport
        let remoteSession: String
        var persistentBackend: String? = nil

        var transportLabel: String {
            switch transport {
            case .ssh, .sshFallback: "SSH"
            case .mosh: "Mosh"
            case .eternalTerminal: "ET"
            }
        }
    }

    var statuses: [SessionConnectionStatus] {
        (fileStatus.map { [$0] } ?? panes.map(\.status)).reduce(into: []) {
            if !$0.contains($1) { $0.append($1) }
        }
    }
    var badges: [String] {
        panes.flatMap { [$0.transportLabel] + [$0.persistentBackend].compactMap { $0 } }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var statusLabel: String { statuses.map(\.label).joined(separator: " · ") }
    var icon: String { id.view == .files ? "folder" : "terminal" }

    static func entries(server: Server, tabManager: TerminalTabManager,
                        fileTabs: RemoteFileTabManager, fileBrowser: RemoteFileBrowserStore) -> [Self] {
        let backend = tabManager.remoteSessionCoordinator.backendMetadata.first {
            $0.identifier == server.remoteSessionBackendIdentifier
        }?.displayName ?? server.remoteSessionBackendIdentifier.rawValue
        let terminals = tabManager.sessionState.tabs(for: server.id).enumerated().map { index, tab in
            let title = tabManager.titleStore.displayTitle(for: tab)
            return Self(id: .terminal(serverID: server.id, tabID: tab.id),
                 title: title == server.name
                    ? LocalizedFormat.string("Terminal tab %lld", Int64(index) + 1) : title, createdAt: tab.createdAt,
                 panes: tab.allPaneIds.map { paneID in
                     let state = tabManager.sessionState.paneState(for: paneID)
                     let checkpoint = tabManager.transportCoordinator.hasEternalTerminalCheckpoint(for: paneID)
                         || tabManager.transportCoordinator.hasMoshCheckpoint(for: paneID)
                     return Pane(id: paneID,
                                 title: tabManager.titleStore.displayTitle(forPane: paneID, fallback: tab.title) ?? tab.title,
                                 status: state.map { SessionConnectionStatus(pane: $0, hasResumeCheckpoint: checkpoint) } ?? .ended,
                                 transport: state?.activeTransport ?? .ssh,
                                 remoteSession: (state?.remoteSessionStatus ?? .off).shortLabel(backendName: backend),
                                 persistentBackend: state?.remoteSessionStatus == .foreground
                                    || state?.remoteSessionStatus == .background ? backend : nil)
                 }, fileStatus: nil, path: nil)
        }
        let files = fileTabs.tabs(for: server.id).map { tab in
            let state = fileBrowser.state(for: tab)
            let path = state.currentPath ?? tab.lastKnownPath ?? tab.seedPath
            let status: SessionConnectionStatus
            switch state.directoryPhase {
            case .notLoaded, .loaded: status = .ready
            case .loading: status = .loading
            case .failed(let error, _), .failedLink(_, let error): status = .failed(error.localizedDescription)
            }
            // A cached directory is not proof of a live SFTP connection.
            return Self(id: .files(serverID: server.id, tabID: tab.id),
                        title: path ?? String(localized: "Files"), createdAt: tab.createdAt,
                        panes: [], fileStatus: status, path: path)
        }
        return ordered(terminals + files)
    }

    static func ordered(_ entries: [Self]) -> [Self] {
        entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.tabID.uuidString < $1.id.tabID.uuidString
        }
    }
}
#endif
