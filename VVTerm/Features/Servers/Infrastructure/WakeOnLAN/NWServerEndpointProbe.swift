import Foundation
import Network

nonisolated struct NWServerEndpointProbe: ServerEndpointProbing {
    func isReachable(host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: endpointPort
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "app.vivy.VivyTerm.serverWake.endpointProbe")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }

                let completionState = ReachabilityCompletionState()
                let timeoutTask = Task {
                    try? await Task.sleep(for: timeout)
                    connection.cancel()
                }
                let finish: @Sendable (Bool) -> Void = { isReachable in
                    guard completionState.completeOnce() else { return }
                    timeoutTask.cancel()
                    connection.cancel()
                    continuation.resume(returning: isReachable)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(true)
                    case .failed, .cancelled:
                        finish(false)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
