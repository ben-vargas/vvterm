import Foundation
import Testing
@testable import VVTerm

struct RemoteProcessRendererTests {
    @Test func posixArgumentsHaveLiteralGoldenRendering() throws {
        let request = RemoteProcessRequest(payload: .invocation(.init(executable: "/bin/echo",
            arguments: ["", "two words", "a'b", "бел", "$HOME; & | > < `id`", "a\"b"])))
        let rendered = try RemoteProcessRenderer.render(request, shell: .posix(shellName: "sh"))
        #expect(rendered.command == "sh -c " + RemoteProcessRenderer.posixQuote(
            "exec '/bin/echo' '' 'two words' 'a'\\''b' 'бел' '$HOME; & | > < `id`' 'a\"b'"))
    }

    @Test func windowsNativeArgumentsPreserveEmptyQuotesAndTrailingSlashes() {
        #expect(RemoteProcessRenderer.windowsArgument("") == "\"\"")
        #expect(RemoteProcessRenderer.windowsArgument("two words") == "\"two words\"")
        #expect(RemoteProcessRenderer.windowsArgument("a\"b") == "\"a\\\"b\"")
        #expect(RemoteProcessRenderer.windowsArgument("C:\\dir\\") == "\"C:\\dir\\\\\"")
        #expect(RemoteProcessRenderer.windowsArgument("бел & $x") == "\"бел & $x\"")
    }

    @Test func powershellUsesEncodedNativeProcessLauncher() throws {
        var request = RemoteProcessRequest(payload: .invocation(.init(executable: "tool.exe", arguments: ["", "a'b", "a\"b", "бел", "%PATH% & !"])))
        request.environment = ["VALUE": "a'b"]
        request.workingDirectory = "C:\\two words"
        let rendered = try RemoteProcessRenderer.render(request, shell: .powershell(executableName: "powershell.exe"))
        let data = try #require(Data(base64Encoded: String(rendered.command.split(separator: " ").last!)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains("$i.Arguments = '\"\" \"a''b\" \"a\\\"b\" \"бел\" \"%PATH% & !\"'"))
        #expect(script.contains("$i.WorkingDirectory = 'C:\\two words'"))
        #expect(script.contains("$i.EnvironmentVariables['VALUE'] = 'a''b'"))
        #expect(script.hasSuffix("exit $p.ExitCode"))
    }

    @Test func cmdQuotesSupportedValuesAndRejectsExpansion() throws {
        for input in ["", "two words", "бел", "a&b|c<d>e^f"] {
            #expect(try RemoteProcessRenderer.cmdArgument(input) == "\"\(input)\"")
        }
        for input in ["%PATH%", "!name!", "a\"b", "a\nb", "a\rb"] {
            #expect(throws: RemoteProcessFailure.self) { try RemoteProcessRenderer.cmdArgument(input) }
        }
    }

    @Test func invalidRequestsFailBeforeDispatchWithoutEchoingSecrets() throws {
        var request = RemoteProcessRequest(payload: .invocation(.init(executable: "x\0secret")))
        do {
            _ = try RemoteProcessRenderer.render(request, shell: .posix(shellName: "sh"))
            Issue.record("Expected invalid request")
        } catch let error as RemoteProcessFailure {
            #expect(error.dispatch == .notDispatched)
            #expect(!String(describing: error).contains("secret"))
        }
        request = RemoteProcessRequest(payload: .invocation(.init(executable: "true")))
        request.outputLimit.stdoutBytes = -1
        #expect(throws: RemoteProcessFailure.self) { try RemoteProcessRenderer.render(request, shell: .posix(shellName: "sh")) }
    }

    @Test func scriptsUseStdinAndCannotAlsoAcceptCallerInput() throws {
        var request = RemoteProcessRequest(payload: .script(.init(shell: .posix, source: Data("printf hello".utf8))))
        let result = try RemoteProcessRenderer.render(request, shell: .posix(shellName: "sh"))
        #expect(result.command == "sh -c " + RemoteProcessRenderer.posixQuote("exec 'sh' '-s'"))
        #expect(result.stdin == Data("printf hello".utf8))
        #expect(result.closesStdin)
        request.stdin = Data()
        #expect(throws: RemoteProcessFailure.self) { try RemoteProcessRenderer.render(request, shell: .posix(shellName: "sh")) }
    }
}
