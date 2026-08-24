import Foundation

@MainActor
protocol RemoteShellStartupActionRepository: AnyObject {
    func action(for serverID: UUID) -> RemoteShellStartupAction?
    func save(_ action: RemoteShellStartupAction?, for serverID: UUID)
}
