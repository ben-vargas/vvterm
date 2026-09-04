import Foundation
import os.log

extension SSHClient {
    func remoteEnvironment(forceRefresh: Bool = false) async -> RemoteEnvironment {
        guard case .connected(let state) = lifecycle else { return .fallbackPOSIX }
        let environment = await state.environmentCoordinator.environment(forceRefresh: forceRefresh)
        guard case .connected(let current) = lifecycle, current.id == state.id,
              !Task.isCancelled else { return .fallbackPOSIX }
        return environment
    }

    func remoteSystemIdentity() async -> RemoteSystemIdentity? {
        guard case .connected(let state) = lifecycle else { return nil }
        let identity = await state.environmentCoordinator.systemIdentity()
        guard case .connected(let current) = lifecycle, current.id == state.id,
              !Task.isCancelled else { return nil }
        return identity
    }

    func remoteTerminalType(forceRefresh: Bool = false) async -> RemoteTerminalType {
        if !forceRefresh,
           case .connected(let state) = lifecycle,
           let remoteTerminalType = state.remoteTerminalType {
            return remoteTerminalType
        }

        let environment = await remoteEnvironment(forceRefresh: forceRefresh)
        let connectionID: UUID?
        if case .connected(let state) = lifecycle {
            connectionID = state.id
        } else {
            connectionID = nil
        }
        let token = startupTrace?.begin(.terminalType)
        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: environment,
            execute: { [weak self] command, timeout in
                guard let self else { throw SSHError.notConnected }
                return try await self.execute(command, timeout: timeout)
            }
        )
        if let token {
            startupTrace?.end(token, detail: terminalType.rawValue)
        }
        if case .connected(var state) = lifecycle, state.id == connectionID {
            state.remoteTerminalType = terminalType
            lifecycle = .connected(state)
        }
        logger.info("Resolved remote terminal type: \(terminalType.rawValue, privacy: .public)")
        return terminalType
    }

    func remotePlatform(forceRefresh: Bool = false) async -> RemotePlatform {
        await remoteEnvironment(forceRefresh: forceRefresh).platform
    }

    func supportsTmuxRuntime() async -> Bool {
        let environment = await remoteEnvironment()
        return environment.supportsTmuxRuntime
    }

    func supportsMoshRuntime() async -> Bool {
        let environment = await remoteEnvironment()
        return environment.supportsMoshRuntime
    }
}
