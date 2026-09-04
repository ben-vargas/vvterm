import Foundation

/// Shares detection within one SSH connection. Completed tasks retain their result.
actor RemoteEnvironmentCoordinator {
    private enum State {
        case idle
        case resolving(Task<RemoteEnvironment, Never>, identity: Task<RemoteSystemIdentity?, Never>?)
        case cancelled
    }

    private let execute: RemoteEnvironmentResolver.CommandExecutor
    private let trace: SSHStartupTrace?
    private let preferredPlatform: RemotePlatform?
    private var state: State = .idle

    init(execute: @escaping RemoteEnvironmentResolver.CommandExecutor,
         trace: SSHStartupTrace? = nil, preferredPlatform: RemotePlatform? = nil) {
        self.execute = execute
        self.trace = trace
        self.preferredPlatform = preferredPlatform
    }

    func environment(forceRefresh: Bool = false) async -> RemoteEnvironment {
        guard !Task.isCancelled else { return .fallbackPOSIX }
        if case .cancelled = state { return .fallbackPOSIX }
        if forceRefresh {
            cancelTasks()
            state = .idle
        }
        if case .resolving(let task, _) = state {
            let result = await task.value
            return task.isCancelled || Task.isCancelled ? .fallbackPOSIX : result
        }
        let task = Task { [execute, trace, preferredPlatform] in
            let token = trace?.begin(.remoteEnvironment)
            let environment = await RemoteEnvironmentResolver.resolve(preferredPlatform: preferredPlatform) { command, timeout in
                let probeToken = trace?.begin(.environmentProbe)
                do {
                    let output = try await execute(command, timeout)
                    if let probeToken { trace?.end(probeToken) }
                    return output
                } catch {
                    if let probeToken { trace?.end(probeToken, outcome: "failed") }
                    throw error
                }
            }
            if let token { trace?.end(token, detail: environment.platform.rawValue) }
            return environment
        }
        state = .resolving(task, identity: nil)
        let result = await task.value
        return task.isCancelled || Task.isCancelled ? .fallbackPOSIX : result
    }

    func systemIdentity() async -> RemoteSystemIdentity? {
        _ = await environment()
        guard !Task.isCancelled else { return nil }
        guard case .resolving(let environmentTask, let identityTask) = state else { return nil }
        if let identityTask {
            let result = await identityTask.value
            return identityTask.isCancelled || Task.isCancelled ? nil : result
        }
        let task = Task { [execute, trace] in
            let environment = await environmentTask.value
            guard !Task.isCancelled else { return nil as RemoteSystemIdentity? }
            let token = trace?.begin(.systemIdentity)
            let identity = await RemoteSystemIdentityResolver.resolve(environment: environment, execute: execute)
            if let token { trace?.end(token, outcome: Task.isCancelled ? "cancelled" : "ok") }
            return Task.isCancelled ? nil : identity
        }
        state = .resolving(environmentTask, identity: task)
        let result = await task.value
        return task.isCancelled || Task.isCancelled ? nil : result
    }

    func cancel() {
        cancelTasks()
        state = .cancelled
    }

    private func cancelTasks() {
        if case .resolving(let environment, let identity) = state {
            environment.cancel()
            identity?.cancel()
        }
    }

    deinit {
        if case .resolving(let environment, let identity) = state {
            environment.cancel()
            identity?.cancel()
        }
    }
}
