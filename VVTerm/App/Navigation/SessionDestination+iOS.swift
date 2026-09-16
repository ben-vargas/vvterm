#if os(iOS)
import Foundation

enum SessionDestination: Hashable, Identifiable {
    case terminal(serverID: UUID, tabID: UUID)
    case files(serverID: UUID, tabID: UUID)

    var id: Self { self }
    var serverID: UUID {
        switch self {
        case .terminal(let serverID, _), .files(let serverID, _): serverID
        }
    }
    var tabID: UUID {
        switch self {
        case .terminal(_, let tabID), .files(_, let tabID): tabID
        }
    }
    var view: ConnectionViewTabID {
        switch self { case .terminal: .terminal; case .files: .files }
    }
}
#endif
