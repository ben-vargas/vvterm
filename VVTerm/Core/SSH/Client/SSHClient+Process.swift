import Foundation

extension SSHClient {
    /// Streams remain separate unless a PTY was explicitly requested. A remote
    /// PTY may merge stderr into stdout before SSH receives it.
    func startProcess(_ request: RemoteProcessRequest) async throws -> RemoteProcess {
        let (session, profile) = try await processContext(for: request)
        return try await session.startProcess(request, shell: profile)
    }

    func runProcess(_ request: RemoteProcessRequest) async throws -> RemoteProcessResult {
        let (session, profile) = try await processContext(for: request)
        let process = try await session.startProcess(request, shell: profile, mode: .collected)
        return try await process.wait()
    }

    private func processContext(for request: RemoteProcessRequest) async throws -> (SSHSession, RemoteShellProfile) {
        guard !isAborted, let session else {
            throw RemoteProcessFailure(reason: .notConnected, dispatch: .notDispatched)
        }
        let profile: RemoteShellProfile
        if case .rawShell(_, _, .compatibility) = request.payload { profile = .unknown() }
        else {
            let environment = await remoteEnvironment()
            switch request.payload {
            case .invocation, .script:
                if environment.shellProfile.family == .cmd, let executable = environment.powerShellExecutable {
                    profile = .powershell(executableName: executable)
                } else { profile = environment.shellProfile }
            case .rawShell: profile = environment.shellProfile
            }
        }
        guard !Task.isCancelled else { throw RemoteProcessFailure(reason: .cancelled, dispatch: .notDispatched) }
        guard !isAborted, self.session === session else {
            throw RemoteProcessFailure(reason: .notConnected, dispatch: .notDispatched)
        }
        return (session, profile)
    }
}
