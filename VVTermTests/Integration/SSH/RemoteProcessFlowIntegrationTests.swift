import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VVTERM_REMOTE_PROCESS_FIXTURE"] != nil))
struct RemoteProcessFlowIntegrationTests {
    private struct Fixture: Decodable { let port: Int; let password: String; let argumentScript: String }
    private struct LocalHostVerifier: SSHHostKeyVerifying {
        func verify(_ candidate: SSHHostKeyCandidate) -> SSHHostKeyVerificationDecision { .trusted }
    }

    private func connectedSession() async throws -> SSHSession {
        let path = try #require(ProcessInfo.processInfo.environment["VVTERM_REMOTE_PROCESS_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let credentials = ServerCredentials(serverId: UUID(), password: fixture.password)
        let session = SSHSession(config: SSHSessionConfig(host: "127.0.0.1", port: fixture.port,
            username: "vvterm-test", connectionMode: .standard, authMethod: .password,
            credentials: credentials), hostKeyVerifier: LocalHostVerifier())
        try await session.connect()
        return session
    }

    private func run(_ command: String, session: SSHSession, limit: RemoteProcessOutputLimit = .init()) async throws -> RemoteProcessResult {
        var request = RemoteProcessRequest(payload: .rawShell(shell: .posix, command: command, reason: .compatibility))
        request.outputLimit = limit
        request.timeout = .seconds(5)
        let process = try await session.startProcess(request, shell: .posix(shellName: "sh"), mode: .collected)
        return try await process.wait()
    }

    @Test func outputStatusSignalAndMissingStatusStayDistinct() async throws {
        let session = try await connectedSession()
        do {
            let result = try await run("printf stdout; printf stderr >&2; exit 23", session: session)
            #expect(result.stdout == Data("stdout".utf8))
            #expect(result.stderr == Data("stderr".utf8))
            #expect(result.exitStatus == 23)
            #expect(result.exitSignal == nil)
            let success = try await run("true", session: session)
            #expect(success.exitStatus == 0)
            let missing = try await run("__fixture_no_exit__", session: session)
            #expect(missing.exitStatus == nil)
            let signal = try await run("__fixture_signal__", session: session)
            #expect(signal.exitStatus == nil)
            #expect(signal.exitSignal == "TERM")
            let limited = try await run("printf abcdef; printf xyz >&2", session: session,
                                        limit: .init(stdoutBytes: 3, stderrBytes: 2))
            #expect(limited.stdout == Data("abc".utf8))
            #expect(limited.stderr == Data("xy".utf8))
            #expect(limited.stdoutTruncated && limited.stderrTruncated)
            #expect(limited.exitStatus == 0)
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
    }

    @Test func streamsAcceptStdinAndEOF() async throws {
        let session = try await connectedSession()
        do {
            var request = RemoteProcessRequest(payload: .invocation(.init(executable: "cat")))
            request.timeout = .seconds(5)
            let process = try await session.startProcess(request, shell: .posix(shellName: "sh"))
            async let output: Data = collect(process.stdout)
            async let errors: Data = collect(process.stderr)
            try await process.writeStdin(Data("hello\nбел\n".utf8))
            await process.closeStdin()
            let result = try await process.wait()
            #expect(try await output == Data("hello\nбел\n".utf8))
            #expect(try await errors == Data())
            #expect(result.exitStatus == 0)
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
    }

    @Test func timeoutAndCancellationLeaveOtherChannelsUsable() async throws {
        let session = try await connectedSession()
        do {
            var request = RemoteProcessRequest(payload: .invocation(.init(executable: "sleep", arguments: ["10"])))
            request.timeout = .milliseconds(200)
            let process = try await session.startProcess(request, shell: .posix(shellName: "sh"), mode: .collected)
            do { _ = try await process.wait(); Issue.record("Expected timeout") }
            catch let failure as RemoteProcessFailure { #expect(failure.reason == .timeout); #expect(failure.dispatch == .dispatched) }
            request.timeout = .seconds(5)
            let cancelled = try await session.startProcess(request, shell: .posix(shellName: "sh"), mode: .collected)
            await cancelled.cancel()
            do { _ = try await cancelled.wait(); Issue.record("Expected cancellation") }
            catch let failure as RemoteProcessFailure { #expect(failure.reason == .cancelled) }
            #expect(try await run("printf alive", session: session).stdout == Data("alive".utf8))
            #expect(try await session.execute("printf legacy") == "legacy")
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
    }

    @Test func scriptAndInvocationPreserveInputAndArguments() async throws {
        let session = try await connectedSession()
        do {
            let script = RemoteProcessRequest(payload: .script(.init(shell: .posix, source: Data("printf script; printf error >&2; exit 7\n".utf8))))
            let process = try await session.startProcess(script, shell: .posix(shellName: "sh"), mode: .collected)
            let result = try await process.wait()
            #expect(result.stdout == Data("script".utf8)); #expect(result.stderr == Data("error".utf8)); #expect(result.exitStatus == 7)
            let arguments = ["", "a'b", "a\"b", "бел", "$HOME; `id`; & |"]
            let request = RemoteProcessRequest(payload: .invocation(.init(executable: "printf", arguments: ["<%s>"] + arguments)))
            let invocation = try await session.startProcess(request, shell: .posix(shellName: "sh"), mode: .collected)
            #expect(try await invocation.wait().stdout == Data(arguments.map { "<\($0)>" }.joined().utf8))
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
    }

    @Test func slowConsumersFailExplicitlyAndTransportLossKeepsDispatchCertainty() async throws {
        let session = try await connectedSession()
        do {
            var request = RemoteProcessRequest(payload: .invocation(.init(executable: "dd", arguments: ["if=/dev/zero", "bs=32768", "count=128"])))
            request.timeout = .seconds(5)
            request.outputLimit.stdoutBytes = 16
            let slow = try await session.startProcess(request, shell: .posix(shellName: "sh"))
            do { _ = try await slow.wait(); Issue.record("Expected bounded stream overflow") }
            catch let failure as RemoteProcessFailure {
                #expect(failure.reason == .outputOverflow)
                #expect(failure.dispatch == .dispatched)
            }
            #expect(try await run("printf alive", session: session).exitStatus == 0)
            do { _ = try await run("__fixture_drop_before_ack__", session: session); Issue.record("Expected transport loss") }
            catch let failure as RemoteProcessFailure { #expect(failure.dispatch == .unknown) }
            await session.disconnect()
            do {
                _ = try await session.startProcess(request, shell: .posix(shellName: "sh"))
                Issue.record("Expected disconnected request")
            } catch let failure as RemoteProcessFailure { #expect(failure.dispatch == .notDispatched) }
        } catch { await session.disconnect(); throw error }
    }

    @Test func scriptsHonorEnvironmentAndDirectoryAndLegacyBudgetRemainsCombined() async throws {
        let session = try await connectedSession()
        do {
            var request = RemoteProcessRequest(payload: .script(.init(shell: .posix,
                source: Data("printf '%s:%s' \"$PWD\" \"$VVTERM_VALUE\"\n".utf8))))
            request.environment = ["VVTERM_VALUE": "a'b & $PATH"]
            request.workingDirectory = "/"
            let process = try await session.startProcess(request, shell: .posix(shellName: "sh"), mode: .collected)
            #expect(try await process.wait().stdout == Data("/:a'b & $PATH".utf8))
            do {
                _ = try await session.execute("printf abc; printf de >&2", maxOutputBytes: 4)
                Issue.record("Expected combined legacy output limit")
            } catch SSHError.outputLimitExceeded {}
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
    }

    #if os(macOS)
    @Test func powerShellNativeLauncherPreservesLiteralArguments() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pwsh") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let path = try #require(ProcessInfo.processInfo.environment["VVTERM_REMOTE_PROCESS_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let session = try await connectedSession()
        do {
            let arguments = ["", "two words", "a'b", "a\"b", "бел", "%PATH% & !", "trailing\\"]
            var request = RemoteProcessRequest(payload: .invocation(.init(executable: "/opt/homebrew/bin/pwsh",
                arguments: ["-NoProfile", "-NonInteractive", "-File", fixture.argumentScript] + arguments)))
            request.timeout = .seconds(15)
            let process = try await session.startProcess(request, shell: .powershell(executableName: "pwsh"), mode: .collected)
            let result = try await process.wait()
            try #require(result.exitStatus == 0, Comment(rawValue: String(decoding: result.stderr, as: UTF8.self)))
            #expect(try JSONDecoder().decode([String].self, from: result.stdout) == arguments)
            let scriptRequest = RemoteProcessRequest(payload: .script(.init(shell: .powershell,
                source: Data("[Console]::Out.Write('stdin-script'); exit 7\n".utf8))))
            let scriptProcess = try await session.startProcess(scriptRequest, shell: .powershell(executableName: "pwsh"), mode: .collected)
            let scriptResult = try await scriptProcess.wait()
            #expect(scriptResult.stdout == Data("stdin-script".utf8))
            #expect(scriptResult.exitStatus == 7)
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
    }
    #endif

    @Test func cancellingBlockedStdinResumesTheWriter() async throws {
        let session = try await connectedSession()
        do {
            var request = RemoteProcessRequest(payload: .invocation(.init(executable: "sleep", arguments: ["10"])))
            request.timeout = .seconds(5)
            let process = try await session.startProcess(request, shell: .posix(shellName: "sh"))
            let writer = Task {
                for _ in 0..<10 { try await process.writeStdin(Data(repeating: 1, count: 1_048_576)) }
            }
            try await Task.sleep(for: .milliseconds(200))
            writer.cancel()
            do { try await writer.value; Issue.record("Expected writer cancellation") }
            catch let failure as RemoteProcessFailure { #expect(failure.reason == .cancelled) }
            catch is CancellationError {}
            do { _ = try await process.wait(); Issue.record("Expected process cancellation") }
            catch let failure as RemoteProcessFailure { #expect(failure.reason == .cancelled) }
            #expect(try await run("printf alive", session: session).stdout == Data("alive".utf8))
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var data = Data()
        for try await chunk in stream { data.append(chunk) }
        return data
    }
}
