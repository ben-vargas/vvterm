import Foundation
import Testing
@testable import VVTerm

struct RemoteEnvironmentCoordinatorTests {
    @Test
    func windowsHintRunsOneVerifiedWindowsProbe() async {
        let executor = RemoteEnvironmentTests.FakeExecutor(outputs: [.success("""
        __VVTERM_PLATFORM__=Windows
        __VVTERM_DEFAULT_SHELL_BEGIN__
        __VVTERM_WINDOWS_POWERSHELL_BEGIN__
        C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe
        __VVTERM_WINDOWS_PWSH_BEGIN__
        __VVTERM_WINDOWS_PROBE_END__
        """)])
        let coordinator = RemoteEnvironmentCoordinator(execute: { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }, preferredPlatform: .windows)
        #expect(await coordinator.environment().platform == .windows)
        #expect(await executor.recordedCommands() == [RemoteEnvironmentResolver.windowsEnvironmentProbeCommand()])
    }

    @Test
    func staleWindowsHintFallsBackToVerifiedPOSIX() async {
        let executor = RemoteEnvironmentTests.FakeExecutor(outputs: [
            .success("not Windows"),
            .success("__VVTERM_PLATFORM__=Linux\n__VVTERM_SHELL__=zsh")
        ])
        let coordinator = RemoteEnvironmentCoordinator(execute: { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }, preferredPlatform: .windows)
        #expect(await coordinator.environment().platform == .linux)
        #expect(await executor.recordedCommands() == [
            RemoteEnvironmentResolver.windowsEnvironmentProbeCommand(),
            RemoteEnvironmentResolver.posixEnvironmentProbeCommand()
        ])
    }

    private actor Probe {
        var calls = 0
        let started: AsyncStream<Void>.Continuation
        private var release: CheckedContinuation<Void, Never>?

        init(started: AsyncStream<Void>.Continuation) { self.started = started }

        func execute(_ command: String, _ timeout: Duration?) async throws -> String {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.yield(())
                }
            }
            return "__VVTERM_PLATFORM__=Linux\n__VVTERM_SHELL__=zsh"
        }

        func unblock() {
            release?.resume()
            release = nil
        }
    }

    @Test
    func concurrentCallersShareOneProbeAndCompletedResult() async {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let probe = Probe(started: continuation)
        let coordinator = RemoteEnvironmentCoordinator(execute: probe.execute)
        let first = Task { await coordinator.environment() }
        for await _ in started { break }
        let second = Task { await coordinator.environment() }
        await probe.unblock()
        #expect(await first.value.platform == .linux)
        #expect(await second.value.platform == .linux)
        #expect(await coordinator.environment().activeShellName == "zsh")
        #expect(await probe.calls == 1)
    }

    @Test
    func cancellationDiscardsLateResultAndDoesNotRestartDetection() async {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let probe = Probe(started: continuation)
        let coordinator = RemoteEnvironmentCoordinator(execute: probe.execute)
        let task = Task { await coordinator.environment() }
        for await _ in started { break }
        await coordinator.cancel()
        await probe.unblock()
        #expect(await task.value == .fallbackPOSIX)
        #expect(await coordinator.systemIdentity() == nil)
        #expect(await coordinator.environment() == .fallbackPOSIX)
        #expect(await probe.calls == 1)
    }

    @Test
    func identityIsOptionalAndSharesItsOwnResult() async {
        let executor = RemoteEnvironmentTests.FakeExecutor(outputs: [
            .success("__VVTERM_PLATFORM__=Linux\n__VVTERM_SHELL__=zsh"),
            .success("ID=ubuntu\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"")
        ])
        let coordinator = RemoteEnvironmentCoordinator { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }
        #expect(await coordinator.environment().platform == .linux)
        #expect(await executor.recordedCommands().count == 1)
        #expect(await coordinator.systemIdentity()?.kind == .ubuntu)
        #expect(await coordinator.systemIdentity()?.displayName == "Ubuntu 24.04 LTS")
        #expect(await executor.recordedCommands().count == 2)
    }

    @Test
    func refreshDiscardsAnOlderInFlightResult() async {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let probe = Probe(started: continuation)
        let coordinator = RemoteEnvironmentCoordinator(execute: probe.execute)
        let first = Task { await coordinator.environment() }
        for await _ in started { break }
        #expect(await coordinator.environment(forceRefresh: true).platform == .linux)
        await probe.unblock()
        #expect(await first.value == .fallbackPOSIX)
        #expect(await coordinator.environment().platform == .linux)
        #expect(await probe.calls == 2)
    }
}
