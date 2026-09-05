import Foundation
import Testing
@testable import VVTerm

struct ZmxRemoteSessionBackendTests {
    @Test
    func probeParsesAbsoluteExecutableAndMinimumVersion() throws {
        let result = try #require(ZmxRemoteSessionParser.parseProbe("""
        noise
        __VVTERM_ZMX_OK__
        __VVTERM_ZMX_PATH__/usr/local/bin/zmx
        zmx 0.7.0
        """))

        #expect(result.executable.path == "/usr/local/bin/zmx")
        #expect(result.rawVersion == "zmx 0.7.0")
        #expect(result.semanticVersion == ZmxRemoteSessionBackend.minimumVersion)
    }

    @Test(arguments: [
        "__VVTERM_ZMX_OK__\n__VVTERM_ZMX_PATH__zmx\nzmx 0.7.0",
        "__VVTERM_ZMX_OK__\n__VVTERM_ZMX_PATH__/usr/bin/zmx\nunknown",
        "__VVTERM_ZMX_PATH__/usr/bin/zmx\nzmx 0.7.0"
    ])
    func probeRejectsUntrustedOrIncompleteOutput(_ output: String) {
        #expect(ZmxRemoteSessionParser.parseProbe(output) == nil)
    }

    @Test(arguments: ["", "  "])
    func discoveryPreservesBackendAndAttachedClientMetadata(_ prefix: String) throws {
        let sessions = try ZmxRemoteSessionParser.parseSessionList("""
        \(prefix)name=alpha\tpid=10\tclients=0\tcreated=1\tstart_dir=/tmp
        \(prefix)name=team session\tpid=11\tclients=2\tcreated=2\tstart_dir=/srv/team
        """)

        #expect(sessions.map(\.id.backendIdentifier) == [.zmx, .zmx])
        #expect(sessions.map(\.id.rawValue) == ["alpha", "team session"])
        #expect(sessions.map(\.attachedClientCount) == [0, 2])
        #expect(sessions.map(\.cleanupDisposition) == [.safeToDelete, .inUse])
        #expect(sessions.map(\.attachment.ownership) == [.external, .external])
        #expect(sessions.allSatisfy { $0.containerCount == nil })
    }

    @Test
    func explicitLabelIsTheOnlyManagedOwnershipSignal() throws {
        let sessions = try ZmxRemoteSessionParser.parseSessionList("""
        name=vvterm-user-created\tclients=0
        name=plain-name\tclients=0\tvvterm_owner=managed
        """)

        #expect(sessions.map(\.attachment.ownership) == [.external, .managed])
    }

    @Test
    func indentedMetadataPreservesFieldSpacesAndOwnership() throws {
        let output = "  name= team session \tclients=0\tvvterm_owner=managed\tstart_dir=/srv/team "
        let session = try #require(ZmxRemoteSessionParser.parseSessionList(output).first)

        #expect(session.id.rawValue == " team session ")
        #expect(session.attachment.ownership == .managed)
        #expect(ZmxRemoteSessionParser.parseWorkingDirectory(for: session.id, in: output) == "/srv/team ")
    }

    @Test(arguments: ["", "  "])
    func fullListMetadataProvidesTheSessionStartDirectory(_ prefix: String) throws {
        let identifier = try identifier("team session")
        let output = """
        \(prefix)name=other\tpid=10\tclients=0\tcreated=1\tstart_dir=/tmp
        \(prefix)name=team session\tpid=11\tclients=1\tcreated=2\tstart_dir=/srv/team project\trole=dev
        """

        #expect(
            ZmxRemoteSessionParser.parseWorkingDirectory(for: identifier, in: output)
                == "/srv/team project"
        )
        #expect(ZmxRemoteSessionParser.parseWorkingDirectory(
            for: try self.identifier("missing"),
            in: output
        ) == nil)
        let listCommand = try ZmxRemoteSessionCommandBuilder.listCommand(
            scope: .userVisible,
            runtime: runtime()
        )
        #expect(listCommand.contains("'list'"))
        #expect(!listCommand.contains("'--short'"))
    }

    @Test
    func listScopesUseUserAndManagedBackendQueries() throws {
        let userVisible = try ZmxRemoteSessionCommandBuilder.listCommand(
            scope: .userVisible,
            runtime: runtime()
        )
        let managedCleanup = try ZmxRemoteSessionCommandBuilder.listCommand(
            scope: .managedCleanup,
            runtime: runtime()
        )

        #expect(!userVisible.contains("'--where'"))
        #expect(managedCleanup.contains("'--where' 'vvterm_owner=managed'"))
    }

    @Test
    func managedNamesFitZmxSocketBudgetAndRemainDeviceScoped() throws {
        let backend = ZmxRemoteSessionBackend()
        let entityID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = try backend.managedIdentifier(
            deviceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID,
            serverName: "Prod API"
        )
        let second = try backend.managedIdentifier(
            deviceID: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID,
            serverName: "Prod API"
        )

        #expect(first.rawValue.hasPrefix("vvterm-prod-d"))
        #expect(first.rawValue.utf8.count <= RemoteSessionManagedIdentifierPolicy.maximumIdentifierLength)
        #expect(first != second)
    }

    @Test
    func discoveryRejectsDuplicatesAndBoundOverruns() {
        #expect(throws: SSHError.self) {
            try ZmxRemoteSessionParser.parseSessionList("""
            name=same\tclients=0
            name=same\tclients=0
            """)
        }
        for malformed in [
            "  unexpected\tclients=0",
            "name=missing-clients\tpid=1",
            "name=negative\tclients=-1",
            "name=invalid\tclients=unknown"
        ] {
            #expect(throws: SSHError.self) {
                try ZmxRemoteSessionParser.parseSessionList(malformed)
            }
        }
        let tooMany = (0...ZmxRemoteSessionParser.maximumSessionCount)
            .map { "name=session-\($0)\tclients=0" }
            .joined(separator: "\n")
        #expect(throws: SSHError.self) {
            try ZmxRemoteSessionParser.parseSessionList(tooMany)
        }
        #expect(throws: SSHError.self) {
            try ZmxRemoteSessionParser.parseSessionList(
                String(repeating: "x", count: ZmxRemoteSessionParser.maximumOutputBytes + 1)
            )
        }
    }

    @Test
    func launchUsesTypedArgumentsAbsolutePathAndCleanEnvironment() throws {
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(
                identifier: try identifier("team '$(touch no)"),
                initialCommand: "printf startup"
            ),
            workingDirectory: "/srv/$(touch no)",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let plan = try ZmxRemoteSessionBackend().launchPlan(
            for: request,
            runtime: runtime()
        )

        #expect(plan.command.contains("env '-u' 'ZMX_SESSION' '-u' 'ZMX_SESSION_PREFIX'"))
        #expect(plan.command.contains("'/opt/homebrew/bin/zmx' 'attach'"))
        #expect(plan.command.contains("set . 'vvterm_owner=managed'"))
        #expect(plan.command.contains("printf startup"))
        #expect(plan.command.contains("grep -Fqx --"))
        #expect(plan.command.contains(#"\$(touch no)"#))
        #expect(!plan.command.contains(#"; $(touch no)"#))
        #expect(plan.command.contains(RemoteSessionLifecycleMarker.sequence(
            envelope: deterministicRemoteSessionLifecycleEnvelope,
            event: .detached
        )))
        #expect(plan.presenceProbe.sessionExists(in: plan.presenceProbe.existsMarker) == true)
        #expect(plan.presenceProbe.sessionExists(in: plan.presenceProbe.missingMarker) == false)
    }

    @Test
    func managedCreationAcceptsAMultilineInitialCommand() throws {
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(
                identifier: try identifier("multiline"),
                initialCommand: "cd /srv/project\nprintf '%s\\n' ready"
            ),
            workingDirectory: "/srv/project",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let command = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request,
            runtime: runtime()
        )

        #expect(command.contains("/bin/sh -lc"))
        #expect(command.contains("cd /srv/project"))
        #expect(command.contains("ready"))
    }

    @Test
    func attachExistingChecksPresenceAndKillUsesForce() throws {
        let attachment = RemoteSessionAttachment(
            identifier: try identifier("shared"),
            ownership: .external
        )
        let request = RemoteSessionLaunchRequest(
            intent: .attach(attachment),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let launch = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request,
            runtime: runtime()
        )
        let kill = try ZmxRemoteSessionCommandBuilder.killCommand(
            identifier: attachment.identifier,
            runtime: runtime()
        )

        #expect(launch.contains("if env '-u' 'ZMX_SESSION'"))
        #expect(!launch.contains("set . 'vvterm_owner=managed'"))
        #expect(!launch.contains("printf startup"))
        #expect(kill.contains("'kill' 'shared' '--force'"))
    }

    @Test
    func managedReattachRestoresItsExplicitOwnershipLabel() throws {
        let request = RemoteSessionLaunchRequest(
            intent: .attach(RemoteSessionAttachment(
                identifier: try identifier("legacy-managed"),
                ownership: .managed
            )),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let launch = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request,
            runtime: runtime()
        )

        #expect(launch.contains("'set' 'legacy-managed' 'vvterm_owner=managed'"))
        #expect(!launch.contains("printf startup"))
    }

    @Test
    func tmuxAdapterUsesResolvedAbsoluteExecutable() throws {
        let identifier = try RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "managed"
        )
        let runtime = RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: try RemoteSessionExecutable(validating: "/opt/tools/tmux"),
            implementationVariant: "unix-tmux",
            rawVersion: "tmux 3.5a",
            semanticVersion: RemoteSessionSemanticVersion("3.5"),
            shellFamily: .posix,
            shellExecutable: "/bin/zsh"
        ))
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(identifier: identifier, initialCommand: nil),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let plan = try TmuxRemoteSessionBackend(tmux: RemoteTmuxManager())
            .launchPlan(for: request, runtime: runtime)

        #expect(plan.command.contains("'/opt/tools/tmux'"))
    }

    private func identifier(_ rawValue: String) throws -> RemoteSessionIdentifier {
        try RemoteSessionIdentifier(backendIdentifier: .zmx, validating: rawValue)
    }

    private func runtime() throws -> RemoteSessionRuntime {
        RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .zmx,
            executable: try RemoteSessionExecutable(validating: "/opt/homebrew/bin/zmx"),
            implementationVariant: "zmx",
            rawVersion: "zmx 0.7.0",
            semanticVersion: RemoteSessionSemanticVersion("0.7.0"),
            shellFamily: .posix,
            shellExecutable: "/bin/zsh"
        ))
    }
}
