import Foundation
import Testing
@testable import VVTerm

struct RemoteTmuxSessionListTests {
    private let backend = RemoteTmuxBackend.windowsPsmux(
        commandName: "psmux", shellFamily: .powershell, powerShellExecutable: "pwsh"
    )

    @Test(arguments: ["\n", "\r\n", "\r"])
    func confirmedEmptyListStopsFallback(_ newline: String) async throws {
        let executor = RemoteEnvironmentTests.FakeExecutor(outputs: [
            .success(RemoteTmuxCommandBuilder.sessionListSuccessMarker + newline)
        ])
        let sessions = try await RemoteTmuxManager().listSessions(backend: backend) { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }
        #expect(sessions.isEmpty)
        #expect(await executor.recordedCommands().count == 1)
    }

    @Test
    func unconfirmedEmptyAndMalformedOutputKeepFallback() async throws {
        let executor = RemoteEnvironmentTests.FakeExecutor(outputs: [
            .success(""),
            .success("not a session\n" + RemoteTmuxCommandBuilder.sessionListSuccessMarker),
            .success("work 0\r\n" + RemoteTmuxCommandBuilder.sessionListSuccessMarker)
        ])
        let sessions = try await RemoteTmuxManager().listSessions(backend: backend) { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }
        #expect(sessions.map(\.name) == ["work"])
        #expect(await executor.recordedCommands().count == 3)
    }

    @Test(arguments: ["", "work 0", "not a session", "not a session\n" + RemoteTmuxCommandBuilder.sessionListSuccessMarker])
    func exhaustedInvalidResponsesAreNotAnEmptyList(_ response: String) async {
        await #expect(throws: SSHError.self) {
            _ = try await RemoteTmuxManager().listSessions(backend: backend) { _, _ in response }
        }
    }
}
