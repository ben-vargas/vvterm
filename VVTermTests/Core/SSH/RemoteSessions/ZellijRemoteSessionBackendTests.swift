import Foundation
import Testing
@testable import VVTerm

private actor ZellijProbeExecutor {
    private let result: Result<String, Error>
    private var commands: [String] = []

    init(_ result: Result<String, Error>) {
        self.result = result
    }

    func run(_ command: String) throws -> String {
        commands.append(command)
        return try result.get()
    }

    func recordedCommands() -> [String] {
        commands
    }
}

private final class ZellijFixtureBundleToken {}

struct ZellijRemoteSessionBackendTests {
    @Test(arguments: ["0.44.3", "0.45.0"])
    func probePinsSupportedCLIVersions(_ version: String) throws {
        let result = try #require(ZellijRemoteSessionParser.parseProbe("""
        noise
        __VVTERM_ZELLIJ_OK__
        __VVTERM_ZELLIJ_PATH__/usr/local/bin/zellij
        zellij \(version)
        """))

        #expect(result.executable.path == "/usr/local/bin/zellij")
        #expect(result.rawVersion == "zellij \(version)")
        #expect(result.semanticVersion == RemoteSessionSemanticVersion(version))
        #expect(ZellijRemoteSessionBackend.supportedVersions.contains(result.semanticVersion))
    }

    @Test
    func availabilityDistinguishesMissingUnsupportedAndInvalidResponses() async {
        let missing = await availability(
            output: .success(ZellijRemoteSessionCommandBuilder.missingMarker)
        )
        let oldPatch = await availability(output: .success(probeOutput(version: "0.44.2")))
        let unpinnedPatch = await availability(
            output: .success(probeOutput(version: "0.45.1"))
        )
        let futureMinor = await availability(
            output: .success(probeOutput(version: "0.46.0"))
        )
        let invalid = await availability(output: .success("unexpected"))

        #expect(missing == .confirmedMissing)
        #expect({ if case .incompatible = oldPatch { true } else { false } }())
        #expect({ if case .incompatible = unpinnedPatch { true } else { false } }())
        #expect({ if case .incompatible = futureMinor { true } else { false } }())
        #expect(invalid == .indeterminate(.invalidResponse))
    }

    @Test
    func unsupportedPlatformDoesNotProbe() async {
        let backend = ZellijRemoteSessionBackend()
        let executor = ZellijProbeExecutor(.success("unexpected"))
        let windows = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )

        let result = await backend.availability(in: windows) { command in
            try await executor.run(command)
        }

        #expect(result == .unsupportedEnvironment)
        #expect(await executor.recordedCommands().isEmpty)
    }

    @Test
    func parserPreservesExplicitOwnershipAndCleanupSafety() throws {
        let sessions = try ZellijRemoteSessionParser.parseSessionList("""
        name=vvterm-user-created\townership=external\tclients=0
        name=managed-attached\townership=managed\tclients=2
        name=managed-unknown\townership=managed\tclients=?
        name=managed-detached\townership=managed\tclients=0
        """)

        #expect(sessions.map(\.attachment.ownership) == [
            .external, .managed, .managed, .managed
        ])
        #expect(sessions.map(\.cleanupDisposition) == [
            .safeToDelete, .inUse, .unknown, .safeToDelete
        ])
        #expect(
            sessions.first?.id.rawValue == "vvterm-user-created"
                && sessions.first?.attachment.ownership == .external
        )
        #expect(
            RemoteSessionCleanupPolicy.identifiersToDelete(
                from: sessions,
                keeping: []
            ).map(\.rawValue) == ["managed-detached"]
        )
    }

    @Test
    func parserRejectsMalformedDuplicateAndUnboundedLists() {
        for output in [
            "missing metadata",
            "name=bad/name\townership=external\tclients=0",
            "name=bad\townership=guessed\tclients=0",
            "name=bad\townership=managed\tclients=-1",
            "name=bad\townership=managed\tclients=4097"
        ] {
            #expect(throws: SSHError.self) {
                try ZellijRemoteSessionParser.parseSessionList(output)
            }
        }
        #expect(throws: SSHError.self) {
            try ZellijRemoteSessionParser.parseSessionList("""
            name=same\townership=external\tclients=0
            name=same\townership=managed\tclients=0
            """)
        }
        #expect(throws: SSHError.self) {
            try ZellijRemoteSessionParser.parseSessionList(
                String(repeating: "x", count: ZellijRemoteSessionParser.maximumOutputBytes + 1)
            )
        }
        let excessiveList = (0...ZellijRemoteSessionParser.maximumSessionCount)
            .map { "name=s\($0)\townership=external\tclients=0" }
            .joined(separator: "\n")
        #expect(throws: SSHError.self) {
            try ZellijRemoteSessionParser.parseSessionList(excessiveList)
        }
    }

    @Test
    func workingDirectoryMustBeAbsoluteBoundedAndLive() {
        let valid = """
        [{"is_plugin":false,"is_focused":false,"exited":false,"pane_cwd":"/srv/old"},{"is_plugin":false,"is_focused":true,"exited":false,"pane_cwd":"/srv/project"}]
        """
        let exited = """
        [{"is_plugin":false,"is_focused":true,"exited":true,"pane_cwd":"/srv/stale"}]
        """
        let relative = """
        [{"is_plugin":false,"is_focused":true,"exited":false,"pane_cwd":"relative"}]
        """
        let tooLongPath = "/" + String(
            repeating: "x",
            count: RemoteSessionExecutable.maximumLength
        )
        let tooLong = """
        [{"is_plugin":false,"is_focused":true,"exited":false,"pane_cwd":"\(tooLongPath)"}]
        """

        #expect(ZellijRemoteSessionParser.parseWorkingDirectory(valid) == "/srv/project")
        #expect(ZellijRemoteSessionParser.parseWorkingDirectory(exited) == nil)
        #expect(ZellijRemoteSessionParser.parseWorkingDirectory(relative) == nil)
        #expect(ZellijRemoteSessionParser.parseWorkingDirectory(tooLong) == nil)
        #expect(ZellijRemoteSessionParser.parseWorkingDirectory("not-json") == nil)
    }

    @Test
    func workingDirectoryLookupRequestsAllPaneFields() throws {
        let command = try ZellijRemoteSessionCommandBuilder.listPanesCommand(
            attachment: RemoteSessionAttachment(
                identifier: identifier("work"),
                ownership: .external
            ),
            runtime: runtime()
        )

        #expect(command.contains("'action' 'list-panes' '--all' '--json'"))
    }

    @Test
    func managedNamesAreDeterministicAndFitUTF8Bounds() throws {
        let backend = ZellijRemoteSessionBackend()
        let entityID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = try backend.managedIdentifier(
            deviceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID,
            serverName: "Prod API 🚀"
        )
        let repeated = try backend.managedIdentifier(
            deviceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID,
            serverName: "Prod API 🚀"
        )

        #expect(first == repeated)
        #expect(first.rawValue.utf8.count <= RemoteSessionIdentifier.maximumRawValueLength)
        #expect(ZellijRemoteSessionParser.isValidSessionName(first.rawValue))
    }

    @Test
    func listScopesUseSeparateNamespacesAndLiveActions() throws {
        let external = try ZellijRemoteSessionCommandBuilder.listCommand(
            scope: .userVisible,
            runtime: runtime()
        )
        let managed = try ZellijRemoteSessionCommandBuilder.listCommand(
            scope: .managedCleanup,
            runtime: runtime()
        )

        for command in [external, managed] {
            #expect(command.contains("'list-sessions' '--short' '--no-formatting'"))
            #expect(command.contains("'action' 'list-panes' '--json'"))
            #expect(command.contains("'action' 'list-clients'"))
            #expect(!command.contains("EXITED"))
            #expect(!command.localizedCaseInsensitiveContains("resurrect"))
        }
        #expect(!external.contains("ZELLIJ_SOCKET_DIR="))
        #expect(external.contains("ownership=%s\tclients=%s"))
        #expect(managed.contains("ZELLIJ_SOCKET_DIR="))
        #expect(managed.contains("/tmp/vvterm-zellij-"))
        #expect(managed.contains("vvtermZellijOwnershipMarker"))
    }

    @Test
    func blankManagedCreationUsesNativeShellAndDisablesSerialization() throws {
        let command = try launchCommand(
            intent: .ensureManaged(
                identifier: identifier("work session"),
                initialCommand: " \n "
            )
        )

        #expect(command.contains("'attach' '--create-background' 'work session'"))
        #expect(command.contains("'options' '--session-serialization' 'false'"))
        #expect(!command.contains("--layout-string"))
        #expect(!command.contains("'/bin/sh' '-lc'"))
        #expect(!command.contains("ZELLIJ_CONFIG_DIR"))
        #expect(!command.contains("ZELLIJ_CONFIG_FILE"))
    }

    @Test
    func customManagedCreationUsesOneNativeKDLLayout() throws {
        let command = try launchCommand(
            intent: .ensureManaged(
                identifier: identifier("work session"),
                initialCommand: "cd ~/project && printf 'ready' && exec $SHELL -l"
            )
        )

        #expect(command.contains("'--layout-string'"))
        #expect(command.contains("pane command="))
        #expect(command.contains("args"))
        #expect(command.contains("'attach' '--create-background' 'work session'"))
        #expect(command.contains("'options' '--session-serialization' 'false'"))
        #expect(!command.contains("'run'"))
        #expect(!command.contains("run --in-place"))
        #expect(!command.contains("focus-pane-with-id"))
        #expect(!command.contains("send-keys"))
        #expect(!command.contains("send-text"))
        #expect(!command.contains("delete-session"))
        #expect(!command.contains("incomplete"))
        #expect(!command.contains("dispatched"))
    }

    @Test
    func attachNeverCarriesAnInitialCommandOrCreationOption() throws {
        let attachment = RemoteSessionAttachment(
            identifier: try identifier("vvterm-user-created"),
            ownership: .external
        )
        let command = try launchCommand(intent: .attach(attachment))

        #expect(command.contains("'attach' 'vvterm-user-created'"))
        #expect(command.contains("'action' 'list-panes' '--json'"))
        #expect(!command.contains("--create"))
        #expect(!command.contains("--layout-string"))
        #expect(!command.contains("ZELLIJ_SOCKET_DIR="))
        #expect(!command.contains("/srv/default"))
    }

    @Test
    func presenceUsesLiveProbeAndExplicitManagedOwnership() throws {
        let external = try ZellijRemoteSessionCommandBuilder.presenceProbe(
            attachment: RemoteSessionAttachment(
                identifier: identifier("vvterm-user-created"),
                ownership: .external
            ),
            runtime: runtime()
        )
        let managed = try ZellijRemoteSessionCommandBuilder.presenceProbe(
            attachment: RemoteSessionAttachment(
                identifier: identifier("managed"),
                ownership: .managed
            ),
            runtime: runtime()
        )

        #expect(external.command.contains("'action' 'list-panes' '--json'"))
        #expect(!external.command.contains("list-sessions"))
        #expect(!external.command.contains("ZELLIJ_SOCKET_DIR="))
        #expect(managed.command.contains("vvtermZellijOwnershipMarker"))
        #expect(managed.command.contains("ZELLIJ_SOCKET_DIR="))
        #expect(external.sessionExists(in: external.existsMarker) == true)
        #expect(external.sessionExists(in: external.missingMarker) == false)
        #expect(external.sessionExists(in: "unrelated") == nil)
    }

    @Test
    func KDLStringEncoderPreservesBytesWithoutShellQuoting() throws {
        let input = "\"\\\n\r\té$`(){};\u{0001}"
        let expected = "\""
            + "\\\""
            + "\\\\"
            + "\\n"
            + "\\r"
            + "\\t"
            + "é$`(){};"
            + "\\u{1}"
            + "\""

        #expect(try ZellijKDLStringEncoder.encode(input) == expected)
        #expect(try ZellijKDLStringEncoder.encode("$(echo no) `echo no`")
            == "\"$(echo no) `echo no`\"")
        #expect(throws: ZellijKDLStringEncoder.EncodingError.outputTooLong) {
            try ZellijKDLStringEncoder.encode(
                String(repeating: "\\", count: ZellijKDLStringEncoder.maximumEncodedByteCount)
            )
        }
    }

    @Test
    func runtimeRejectsUnpinnedVersionsAndDeclaresStartupSupport() throws {
        #expect(ZellijRemoteSessionBackend().metadata.managedStartupCommandSupport == .supported)
        #expect(throws: SSHError.self) {
            try ZellijRemoteSessionBackend().launchPlan(
                for: launchRequest(
                    intent: .ensureManaged(
                        identifier: self.identifier("managed"),
                        initialCommand: nil
                    )
                ),
                runtime: self.runtime(version: "0.45.1")
            )
        }
    }

    #if os(macOS)
    @Test
    func externalListingIncludesOnlyProvenLiveSessions() throws {
        let fixture = try makeFixture(mode: "external")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let command = try ZellijRemoteSessionCommandBuilder.listCommand(
            scope: .userVisible,
            runtime: runtime(executablePath: fixture.executable.path)
        )

        let result = try runPOSIXScript(command, environment: fixture.environment)
        let sessions = try ZellijRemoteSessionParser.parseSessionList(result.output)

        #expect(result.status == 0, Comment(rawValue: result.error))
        #expect(sessions.map(\.id.rawValue) == ["live", "vvterm-user-created"])
        #expect(sessions.map(\.attachment.ownership) == [.external, .external])
        #expect(sessions.map(\.cleanupDisposition) == [.inUse, .safeToDelete])
    }

    @Test
    func managedListingRequiresAnOwnershipMarker() throws {
        let fixture = try makeFixture(mode: "managed")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let socket = fixture.directory.appendingPathComponent("socket", isDirectory: true)
        try makeManagedSocketDirectory(socket, ownedSessions: ["managed-live"])
        let rawCommand = try ZellijRemoteSessionCommandBuilder.listCommand(
            scope: .managedCleanup,
            runtime: runtime(executablePath: fixture.executable.path)
        )
        let command = commandUsingManagedSocket(socket, rawCommand: rawCommand)

        let result = try runPOSIXScript(command, environment: fixture.environment)
        let sessions = try ZellijRemoteSessionParser.parseSessionList(result.output)

        #expect(result.status == 0, Comment(rawValue: result.error))
        #expect(sessions.map(\.id.rawValue) == ["managed-live"])
        #expect(sessions.allSatisfy { $0.attachment.ownership == .managed })
        #expect(sessions.first?.cleanupDisposition == .safeToDelete)
    }

    @Test(arguments: ["oversized", "too-many"])
    func listingRejectsUnboundedRemoteData(_ mode: String) throws {
        let fixture = try makeFixture(mode: mode)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let command = try ZellijRemoteSessionCommandBuilder.listCommand(
            scope: .userVisible,
            runtime: runtime(executablePath: fixture.executable.path)
        )

        let result = try runPOSIXScript(command, environment: fixture.environment)

        #expect(result.status != 0)
        #expect(result.output.utf8.count <= ZellijRemoteSessionParser.maximumOutputBytes)
    }

    @Test
    func managedCreationIgnoresLongTMPDIRAndDoesNotBootstrapShellText() throws {
        let fixture = try makeFixture(mode: "creation")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let socket = fixture.directory.appendingPathComponent("socket", isDirectory: true)
        try makeManagedSocketDirectory(socket, ownedSessions: [])
        let longTemporaryDirectory = fixture.directory.appendingPathComponent(
            String(repeating: "long-path-", count: 20),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: longTemporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = fixture.directory.appendingPathComponent("must-not-exist")
        let startupCommand = """
        printf '"quote" \\ slash ☃'; $(touch \(sentinel.path)); `touch \(sentinel.path)`
        exec $SHELL -l
        """
        let rawCommand = try launchCommand(
            intent: .ensureManaged(
                identifier: identifier("managed"),
                initialCommand: startupCommand
            ),
            executablePath: fixture.executable.path,
            workingDirectory: fixture.directory.path
        )
        let command = commandUsingManagedSocket(socket, rawCommand: rawCommand)
        var environment = fixture.environment
        environment["TMPDIR"] = longTemporaryDirectory.path

        let result = try runPOSIXScript(command, environment: environment)
        let capturedLayout = try String(
            contentsOf: fixture.directory.appendingPathComponent("layout"),
            encoding: .utf8
        )

        #expect(result.status == 0, Comment(rawValue: result.error))
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(capturedLayout.contains("layout { pane command=\"/bin/sh\""))
        #expect(capturedLayout.contains("\\n"))
        #expect(capturedLayout.contains("$(touch"))
        #expect(capturedLayout.contains("`touch"))
        #expect(capturedLayout.contains("☃"))
    }

    @Test
    func twoConcurrentCreatorsDispatchOneNativeCreation() throws {
        let fixture = try makeFixture(mode: "creation")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let socket = fixture.directory.appendingPathComponent("socket", isDirectory: true)
        try makeManagedSocketDirectory(socket, ownedSessions: [])
        let rawCommand = try launchCommand(
            intent: .ensureManaged(
                identifier: identifier("managed"),
                initialCommand: "printf once; exec $SHELL -l"
            ),
            executablePath: fixture.executable.path,
            workingDirectory: fixture.directory.path
        )
        let command = commandUsingManagedSocket(socket, rawCommand: rawCommand)
        let concurrentScript = """
        (\(command)) >/dev/null 2>&1 & vvtermFirst=$!
        (\(command)) >/dev/null 2>&1 & vvtermSecond=$!
        wait "$vvtermFirst"; vvtermFirstStatus=$?
        wait "$vvtermSecond"; vvtermSecondStatus=$?
        printf '%s:%s' "$vvtermFirstStatus" "$vvtermSecondStatus"
        """

        let result = try runPOSIXScript(
            concurrentScript,
            environment: fixture.environment
        )
        let creationLog = try String(
            contentsOf: fixture.directory.appendingPathComponent("creations"),
            encoding: .utf8
        )

        #expect(result.output == "0:0", Comment(rawValue: result.error))
        #expect(creationLog.split(whereSeparator: \.isNewline).count == 1)
    }

    @Test
    func failedCreatorNeverDeletesAConcurrentOrPreexistingSession() throws {
        let command = try launchCommand(
            intent: .ensureManaged(
                identifier: identifier("managed"),
                initialCommand: "printf once"
            )
        )

        #expect(!command.contains("delete-session"))
        #expect(!command.contains("kill-session"))
        #expect(command.contains("vvtermZellijCreateStatus"))
        #expect(command.contains("vvtermZellijState"))
    }

    @Test
    func managedKillRequiresOwnershipAndRemovesMarkerAfterSuccess() throws {
        let command = try ZellijRemoteSessionCommandBuilder.killManagedCommand(
            identifier: identifier("managed"),
            runtime: runtime()
        )

        #expect(command.contains("vvtermZellijOwnershipMarker"))
        #expect(command.contains("'kill-session' 'managed'"))
        #expect(command.contains("rm -f"))
        #expect(command.contains("ZELLIJ_SOCKET_DIR="))
    }
    #endif

    private func availability(
        output: Result<String, Error>
    ) async -> RemoteSessionAvailability {
        let executor = ZellijProbeExecutor(output)
        return await ZellijRemoteSessionBackend().availability(in: .fallbackPOSIX) { command in
            try await executor.run(command)
        }
    }

    private func probeOutput(version: String) -> String {
        """
        \(ZellijRemoteSessionCommandBuilder.availableMarker)
        \(ZellijRemoteSessionCommandBuilder.pathMarker)/opt/tools/zellij
        zellij \(version)
        """
    }

    private func launchCommand(
        intent: RemoteSessionLaunchIntent,
        executablePath: String = "/opt/tools/zellij",
        workingDirectory: String = "/srv/default"
    ) throws -> String {
        try ZellijRemoteSessionBackend().launchPlan(
            for: launchRequest(
                intent: intent,
                workingDirectory: workingDirectory
            ),
            runtime: runtime(executablePath: executablePath)
        ).command
    }

    private func launchRequest(
        intent: RemoteSessionLaunchIntent,
        workingDirectory: String = "/srv/default"
    ) -> RemoteSessionLaunchRequest {
        RemoteSessionLaunchRequest(
            intent: intent,
            workingDirectory: workingDirectory,
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )
    }

    private func identifier(_ rawValue: String) throws -> RemoteSessionIdentifier {
        try RemoteSessionIdentifier(backendIdentifier: .zellij, validating: rawValue)
    }

    private func runtime(
        version: String = "0.45.0",
        executablePath: String = "/opt/tools/zellij"
    ) throws -> RemoteSessionRuntime {
        let parsedVersion = try #require(RemoteSessionSemanticVersion(version))
        return RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .zellij,
            executable: try RemoteSessionExecutable(validating: executablePath),
            implementationVariant: "zellij-\(parsedVersion.major).\(parsedVersion.minor)",
            rawVersion: "zellij \(version)",
            semanticVersion: parsedVersion,
            shellFamily: .posix,
            shellExecutable: "/bin/zsh"
        ))
    }

    #if os(macOS)
    private func makeFixture(
        mode: String
    ) throws -> (directory: URL, executable: URL, environment: [String: String]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let bundle = Bundle(for: ZellijFixtureBundleToken.self)
        let executable = try #require(
            bundle.url(
                forResource: "zellij-fixture",
                withExtension: "sh",
                subdirectory: "Core/SSH/RemoteSessions/Fixtures"
            ) ?? bundle.url(forResource: "zellij-fixture", withExtension: "sh")
        )
        var environment = ProcessInfo.processInfo.environment
        environment["VVTERM_ZELLIJ_FIXTURE_DIR"] = directory.path
        environment["VVTERM_ZELLIJ_FIXTURE_MODE"] = mode
        return (directory, executable, environment)
    }

    private func makeManagedSocketDirectory(
        _ socket: URL,
        ownedSessions: [String]
    ) throws {
        let ownership = socket
            .appendingPathComponent(".vvterm", isDirectory: true)
            .appendingPathComponent("owned", isDirectory: true)
        let locks = socket
            .appendingPathComponent(".vvterm", isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)
        for directory in [socket, ownership, locks] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        for session in ownedSessions {
            let marker = ownership.appendingPathComponent(session)
            try "managed-v1\n".write(to: marker, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: marker.path
            )
        }
    }

    private func commandUsingManagedSocket(
        _ socket: URL,
        rawCommand: String
    ) -> String {
        let production = "ZELLIJ_SOCKET_DIR=\"/tmp/vvterm-zellij-$vvtermZellijUID\""
        let escapedProduction = production
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
        let replacement = "ZELLIJ_SOCKET_DIR=\\\"\(socket.path)\\\""
        precondition(rawCommand.contains(escapedProduction))
        return rawCommand.replacingOccurrences(of: escapedProduction, with: replacement)
    }

    private func runPOSIXScript(
        _ script: String,
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
    #endif
}
