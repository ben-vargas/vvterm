import Foundation
import Testing
@testable import VVTerm

private actor HerdrProbeExecutor {
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

struct HerdrRemoteSessionBackendTests {
    @Test(arguments: [
        ("0.7.5", "herdr-0.7"),
        ("0.8.2", "herdr-0.8")
    ])
    func supportedSeriesProbeAndBuildLifecycleCommands(
        version: String,
        expectedVariant: String
    ) async throws {
        let backend = HerdrRemoteSessionBackend()
        let availability = await availability(
            backend: backend,
            output: .success(probeOutput(version: version))
        )
        guard case .available(let probe) = availability else {
            Issue.record("Herdr \(version) must be available")
            return
        }
        #expect(probe.implementationVariant == expectedVariant)

        let runtime = try runtime(version: version, variant: expectedVariant)
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(
                identifier: try identifier("vvterm-managed"),
                initialCommand: nil
            ),
            workingDirectory: "/srv/project",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )
        let plan = try backend.launchPlan(for: request, runtime: runtime)

        #expect(plan.command.contains("'session' 'attach' 'vvterm-managed'"))
        #expect(plan.command.contains(".vvterm-managed"))
        #expect(plan.command.contains("'status' 'server'"))
        #expect(plan.presenceProbe.command.contains("'status' 'server'"))
    }

    @Test
    func availabilityDistinguishesMissingOldAndUnsupportedSeries() async {
        let backend = HerdrRemoteSessionBackend()
        let missing = await availability(
            backend: backend,
            output: .success(HerdrRemoteSessionCommandBuilder.missingMarker)
        )
        let old07 = await availability(
            backend: backend,
            output: .success(probeOutput(version: "0.7.4"))
        )
        let old08 = await availability(
            backend: backend,
            output: .success(probeOutput(version: "0.8.1"))
        )
        let unsupportedMinor = await availability(
            backend: backend,
            output: .success(probeOutput(version: "0.9.0"))
        )

        #expect(missing == .confirmedMissing)
        #expect({ if case .incompatible = old07 { true } else { false } }())
        #expect({ if case .incompatible(let probe) = old08 {
            probe.implementationVariant == "herdr-0.8"
        } else { false } }())
        #expect({ if case .incompatible(let probe) = unsupportedMinor {
            probe.implementationVariant == "herdr-unsupported"
        } else { false } }())
    }

    @Test
    func unsupportedPlatformDoesNotProbeAndErrorsRemainIndeterminate() async {
        let backend = HerdrRemoteSessionBackend()
        let executor = HerdrProbeExecutor(.success("unexpected"))
        let windows = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let unsupported = await backend.availability(in: windows) { command in
            try await executor.run(command)
        }
        let timeout = await availability(
            backend: backend,
            output: .failure(SSHError.timeout)
        )

        #expect(unsupported == .unsupportedEnvironment)
        #expect(await executor.recordedCommands().isEmpty)
        #expect(timeout == .indeterminate(.timeout))
    }

    @Test
    func realJSONFixtureUsesExplicitOwnershipAndCleanupState() throws {
        let output = sessionFixture(
            managedNames: ["managed-stopped", "managed-live"]
        )
        let userSessions = try HerdrRemoteSessionParser.parseSessionList(
            output,
            scope: .userVisible
        )
        let cleanupSessions = try HerdrRemoteSessionParser.parseSessionList(
            output,
            scope: .managedCleanup
        )

        #expect(userSessions.map(\.id.rawValue) == [
            "default", "vvterm-user-created", "managed-stopped", "managed-live"
        ])
        #expect(userSessions.map(\.attachment.ownership) == [
            .external, .external, .managed, .managed
        ])
        #expect(userSessions.map(\.cleanupDisposition) == [
            .safeToDelete, .unknown, .safeToDelete, .unknown
        ])
        #expect(userSessions.allSatisfy { $0.attachedClientCount == nil })
        #expect(cleanupSessions.map(\.id.rawValue) == ["managed-stopped", "managed-live"])

        let deletable = RemoteSessionCleanupPolicy.identifiersToDelete(
            from: cleanupSessions,
            keeping: []
        )
        #expect(deletable.map(\.rawValue) == ["managed-stopped"])
    }

    @Test
    func vvtermPrefixDoesNotInferManagedOwnership() throws {
        let sessions = try HerdrRemoteSessionParser.parseSessionList(
            sessionFixture(managedNames: []),
            scope: .userVisible
        )
        let prefixed = try #require(
            sessions.first { $0.id.rawValue == "vvterm-user-created" }
        )

        #expect(prefixed.attachment.ownership == .external)
    }

    @Test
    func malformedJSONOwnershipAndBoundsFailSafely() throws {
        for malformed in [
            "not-json",
            "{\"sessions\":[]}\nunknown-metadata",
            "{\"sessions\":[]}\n__VVTERM_HERDR_MANAGED__:stale",
            "{\"sessions\":[]}\n__VVTERM_HERDR_MANAGED__:bad session"
        ] {
            #expect(throws: SSHError.self) {
                try HerdrRemoteSessionParser.parseSessionList(
                    malformed,
                    scope: .userVisible
                )
            }
        }

        let duplicate = """
        {"sessions":[{"default":false,"name":"same","running":true,"session_dir":"/tmp/same","socket_path":"/tmp/same.sock"},{"default":false,"name":"same","running":false,"session_dir":"/tmp/same","socket_path":"/tmp/same.sock"}]}
        """
        #expect(throws: SSHError.self) {
            try HerdrRemoteSessionParser.parseSessionList(
                duplicate,
                scope: .userVisible
            )
        }
        #expect(throws: SSHError.self) {
            try HerdrRemoteSessionParser.parseSessionList(
                String(repeating: "x", count: HerdrRemoteSessionParser.maximumOutputBytes + 1),
                scope: .userVisible
            )
        }

        let records: [[String: Any]] = (0...HerdrRemoteSessionParser.maximumSessionCount)
            .map { index in
                [
                    "default": false,
                    "name": "s\(index)",
                    "running": false,
                    "session_dir": "/tmp/s\(index)",
                    "socket_path": "/tmp/s\(index).sock"
                ]
            }
        let data = try JSONSerialization.data(withJSONObject: ["sessions": records])
        #expect(throws: SSHError.self) {
            try HerdrRemoteSessionParser.parseSessionList(
                String(decoding: data, as: UTF8.self),
                scope: .managedCleanup
            )
        }
    }

    @Test
    func workingDirectoryMustBeAbsoluteAndBounded() {
        let valid = """
        {"id":"cli:pane:current","result":{"pane":{"cwd":"/srv/project","foreground_cwd":"/srv/project/src"}}}
        """
        let relative = """
        {"id":"cli:pane:current","result":{"pane":{"cwd":"relative","foreground_cwd":"also-relative"}}}
        """
        let tooLongPath = "/" + String(
            repeating: "x",
            count: RemoteSessionExecutable.maximumLength
        )
        let tooLong = """
        {"id":"cli:pane:current","result":{"pane":{"cwd":"\(tooLongPath)","foreground_cwd":null}}}
        """

        #expect(HerdrRemoteSessionParser.parseWorkingDirectory(valid) == "/srv/project/src")
        #expect(HerdrRemoteSessionParser.parseWorkingDirectory(relative) == nil)
        #expect(HerdrRemoteSessionParser.parseWorkingDirectory(tooLong) == nil)
    }

    @Test
    func managedNamesAreDeterministicAndFitHerdrByteLimit() throws {
        let backend = HerdrRemoteSessionBackend()
        let entityID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = try backend.managedIdentifier(
            deviceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID,
            serverName: "Prod API"
        )
        let repeatValue = try backend.managedIdentifier(
            deviceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID,
            serverName: "Prod API"
        )

        #expect(first == repeatValue)
        #expect(first.rawValue.utf8.count <= HerdrRemoteSessionParser.maximumSessionNameBytes)
        #expect(HerdrRemoteSessionParser.isValidSessionName(first.rawValue))
    }

    @Test
    func blankStartupCommandCreatesManagedSessionWithoutPaneInjection() throws {
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(
                identifier: try identifier("managed"),
                initialCommand: "  \n  "
            ),
            workingDirectory: "/srv/project",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )
        let command = try HerdrRemoteSessionCommandBuilder.launchCommand(
            request: request,
            runtime: runtime()
        )

        #expect(command.contains("'session' 'attach' 'managed'"))
        #expect(command.contains(".vvterm-managed"))
        #expect(command.contains("umask 077"))
        #expect(!command.contains("'pane' 'run'"))
        #expect(!command.contains("process-info"))
        #expect(!command.contains("creation-lock"))
        #expect(!command.contains("'session' 'stop'"))
        #expect(!command.contains("'session' 'delete'"))
    }

    @Test
    func nonblankStartupCommandFailsAndIsNeverSentToPane() throws {
        let secretMarker = "do-not-send-this-command"
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(
                identifier: try identifier("managed"),
                initialCommand: secretMarker
            ),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        #expect(throws: SSHError.self) {
            try HerdrRemoteSessionBackend().launchPlan(
                for: request,
                runtime: self.runtime()
            )
        }
        #expect(HerdrRemoteSessionBackend().metadata.managedStartupCommandSupport == .unsupported)
    }

    @Test
    func reattachUsesExplicitOwnershipAndCannotRunAnInitialAction() throws {
        let attachment = RemoteSessionAttachment(
            identifier: try identifier("managed"),
            ownership: .managed
        )
        let request = RemoteSessionLaunchRequest(
            intent: .attach(attachment),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )
        let command = try HerdrRemoteSessionCommandBuilder.launchCommand(
            request: request,
            runtime: runtime()
        )

        #expect(command.contains("vvtermHerdrReadOwnership"))
        #expect(command.contains("vvtermHerdrOwnership"))
        #expect(command.contains("'managed'"))
        #expect(!command.contains("pane run"))
        #expect(!command.contains("/bin/sh -lc '/bin/sh -lc"))
    }

    @Test
    func listStopDeleteAndPresenceUseDocumentedCommands() throws {
        let runtime = try runtime()
        let identifier = try identifier("work-1")
        let list = try HerdrRemoteSessionCommandBuilder.listCommand(runtime: runtime)
        let stop = try HerdrRemoteSessionCommandBuilder.stopCommand(
            identifier: identifier,
            runtime: runtime
        )
        let delete = try HerdrRemoteSessionCommandBuilder.deleteCommand(
            identifier: identifier,
            runtime: runtime
        )
        let presence = try HerdrRemoteSessionCommandBuilder.presenceProbe(
            identifier: identifier,
            runtime: runtime
        )

        #expect(list.contains("'session' 'list' '--json'"))
        #expect(list.contains(HerdrRemoteSessionCommandBuilder.managedOwnershipMarkerPrefix))
        #expect(stop.contains("'session' 'stop' 'work-1' '--json'"))
        #expect(delete.contains("'session' 'delete' 'work-1' '--json'"))
        #expect(presence.command.contains("'status' 'server'"))
        #expect(throws: SSHError.self) {
            try HerdrRemoteSessionCommandBuilder.deleteCommand(
                identifier: self.identifier("default"),
                runtime: runtime
            )
        }
    }

    #if os(macOS)
    @Test(arguments: [
        ("printf '%s\\n' 'status: running'", "running"),
        ("printf '%s\\n' 'status: not running'", "stopped"),
        ("printf '%s\\n' 'unexpected'", "unknown")
    ])
    func statusClassificationIsStrict(command: String, expected: String) throws {
        let script = """
        \(HerdrRemoteSessionCommandBuilder.sessionStatusClassificationScript(
            statusCommand: command
        ))
        printf '%s' "$vvtermHerdrRuntimeState"
        """
        let execution = try runShell(script)

        #expect(execution.status == 0)
        #expect(execution.output == expected)
    }
    #endif

    private func availability(
        backend: HerdrRemoteSessionBackend,
        output: Result<String, Error>
    ) async -> RemoteSessionAvailability {
        let executor = HerdrProbeExecutor(output)
        return await backend.availability(in: .fallbackPOSIX) { command in
            try await executor.run(command)
        }
    }

    private func probeOutput(version: String) -> String {
        """
        \(HerdrRemoteSessionCommandBuilder.availableMarker)
        \(HerdrRemoteSessionCommandBuilder.pathMarker)/opt/tools/herdr
        herdr \(version)
        """
    }

    private func sessionFixture(managedNames: [String]) -> String {
        let json = #"{"sessions":[{"default":true,"name":"default","running":false,"session_dir":"/home/me/.config/herdr","socket_path":"/home/me/.config/herdr/herdr.sock"},{"default":false,"name":"vvterm-user-created","running":true,"session_dir":"/home/me/.config/herdr/sessions/vvterm-user-created","socket_path":"/home/me/.config/herdr/sessions/vvterm-user-created/herdr.sock"},{"default":false,"name":"managed-stopped","running":false,"session_dir":"/home/me/.config/herdr/sessions/managed-stopped","socket_path":"/home/me/.config/herdr/sessions/managed-stopped/herdr.sock"},{"default":false,"name":"managed-live","running":true,"session_dir":"/home/me/.config/herdr/sessions/managed-live","socket_path":"/home/me/.config/herdr/sessions/managed-live/herdr.sock"}]}"#
        let markers = managedNames.map {
            HerdrRemoteSessionCommandBuilder.managedOwnershipMarkerPrefix + $0
        }
        return ([json] + markers).joined(separator: "\n")
    }

    private func identifier(_ rawValue: String) throws -> RemoteSessionIdentifier {
        try RemoteSessionIdentifier(backendIdentifier: .herdr, validating: rawValue)
    }

    private func runtime(
        version: String = "0.7.5",
        variant: String = "herdr-0.7"
    ) throws -> RemoteSessionRuntime {
        RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .herdr,
            executable: try RemoteSessionExecutable(validating: "/opt/tools/herdr"),
            implementationVariant: variant,
            rawVersion: "herdr \(version)",
            semanticVersion: RemoteSessionSemanticVersion(version),
            shellFamily: .posix,
            shellExecutable: "/bin/zsh"
        ))
    }

    #if os(macOS)
    private func runShell(_ command: String) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    #endif
}
