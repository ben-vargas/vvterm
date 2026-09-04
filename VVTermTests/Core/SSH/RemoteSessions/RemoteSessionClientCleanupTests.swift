import Foundation
import Testing
@testable import VVTerm

struct RemoteSessionClientCleanupTests {
    private enum Failure: Error, CaseIterable { case list, protection, delete }

    private actor Backend: RemoteSessionBackend {
        nonisolated let metadata = RemoteSessionBackendMetadata(
            identifier: .tmux, displayName: "tmux", installation: .automatic,
            managedStartupCommandSupport: .supported
        )
        let sessions: [RemoteSessionDescriptor]
        var killed: [RemoteSessionIdentifier] = []
        let failure: Failure?

        init(sessions: [RemoteSessionDescriptor], failure: Failure? = nil) {
            self.sessions = sessions
            self.failure = failure
        }

        func availability(using client: SSHClient) async -> RemoteSessionAvailability { .unsupportedEnvironment }
        func listSessions(scope: RemoteSessionListScope, using client: SSHClient,
                          runtime: RemoteSessionRuntime) async throws -> [RemoteSessionDescriptor] {
            if failure == .list { throw Failure.list }
            return sessions
        }
        nonisolated func launchPlan(for request: RemoteSessionLaunchRequest,
                                    runtime: RemoteSessionRuntime) throws -> RemoteSessionBackendLaunchPlan {
            throw SSHError.notConnected
        }
        func installScript(attachment: RemoteSessionAttachment, workingDirectory: String,
                           terminalType: RemoteTerminalType, themeStyle: RemoteSessionThemeStyle,
                           using client: SSHClient, attachAfterInstall: Bool) async -> String? { nil }
        func killSession(_ identifier: RemoteSessionIdentifier, using client: SSHClient,
                         runtime: RemoteSessionRuntime) async throws {
            if failure == .delete { throw Failure.delete }
            killed.append(identifier)
        }
        func currentWorkingDirectory(for attachment: RemoteSessionAttachment, using client: SSHClient,
                                     runtime: RemoteSessionRuntime) async -> String? { nil }
    }

    @Test
    func protectedSessionsAreReadAgainBeforeEachDelete() async throws {
        let first = try identifier("first")
        let second = try identifier("second")
        let backend = Backend(sessions: [descriptor(first), descriptor(second)])
        let client = RemoteSessionClient(registry: .init(backends: [backend]))
        try await client.cleanupSessions(keeping: {
            // A session becomes locally referenced while the first delete runs.
            await backend.killed.isEmpty ? [] : [second]
        }, using: .testing(), runtime: try runtime())
        #expect(await backend.killed == [first])
    }

    @Test(arguments: Failure.allCases)
    private func failuresAreNotReportedAsSuccessfulCleanup(_ failure: Failure) async throws {
        let backend = Backend(sessions: [descriptor(try identifier("first"))], failure: failure)
        let client = RemoteSessionClient(registry: .init(backends: [backend]))
        let runtime = try runtime()
        await #expect(throws: Failure.self) {
            try await client.cleanupSessions(keeping: {
                if failure == .protection { throw Failure.protection }
                return []
            }, using: .testing(), runtime: runtime)
        }
        #expect(await backend.killed.isEmpty)
    }

    @Test
    func cancellationDuringProtectionCheckStopsDeletion() async throws {
        let backend = Backend(sessions: [descriptor(try identifier("first"))])
        let client = RemoteSessionClient(registry: .init(backends: [backend]))
        let runtime = try runtime()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await client.cleanupSessions(keeping: {
                signal.yield(())
                try await Task.sleep(for: .seconds(30))
                return []
            }, using: .testing(), runtime: runtime)
        }
        for await _ in started { break }
        task.cancel()
        _ = await task.result
        #expect(await backend.killed.isEmpty)
    }

    private func identifier(_ name: String) throws -> RemoteSessionIdentifier {
        try RemoteSessionIdentifier(backendIdentifier: .tmux, validating: name)
    }

    private func descriptor(_ identifier: RemoteSessionIdentifier) -> RemoteSessionDescriptor {
        RemoteSessionDescriptor(
            attachment: .init(identifier: identifier, ownership: .managed),
            attachedClientCount: 0, containerCount: 1, cleanupDisposition: .safeToDelete
        )
    }

    private func runtime() throws -> RemoteSessionRuntime {
        RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: try RemoteSessionExecutable(validating: "/usr/bin/tmux"),
            implementationVariant: "tmux-posix", rawVersion: "tmux 3.5",
            semanticVersion: .init(major: 3, minor: 5, patch: 0),
            shellFamily: .posix, shellExecutable: "sh"
        ))
    }
}
