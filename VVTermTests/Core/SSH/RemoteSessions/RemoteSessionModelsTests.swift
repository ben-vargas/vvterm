import Foundation
import Testing
@testable import VVTerm

struct RemoteSessionModelsTests {
    @Test
    func registryExposesStableBuiltInBackendIdentifiers() {
        let registry = RemoteSessionBackendRegistry(backends: [
            ZmxRemoteSessionBackend(),
            TmuxRemoteSessionBackend(tmux: RemoteTmuxManager())
        ])

        #expect(registry.metadata.map(\.identifier) == [.tmux, .zmx])
        #expect(registry.backend(for: .tmux)?.metadata.displayName == "tmux")
        #expect(registry.backend(for: .zmx)?.metadata.displayName == "zmx")
        #expect(registry.metadata.allSatisfy {
            $0.managedStartupCommandSupport == .supported
        })
    }

    @Test
    func launchIntentHasOnlyExplicitAttachOrManagedEnsurePaths() throws {
        let external = RemoteSessionAttachment(
            identifier: try RemoteSessionIdentifier(
                backendIdentifier: .tmux,
                validating: "vvterm-user-created"
            ),
            ownership: .external
        )
        let managedIdentifier = try RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "plain-managed-name"
        )

        let attach = RemoteSessionLaunchIntent.attach(external)
        let ensure = RemoteSessionLaunchIntent.ensureManaged(
            identifier: managedIdentifier,
            initialCommand: "printf ready"
        )

        #expect(attach.attachment == external)
        #expect(ensure.attachment == RemoteSessionAttachment(
            identifier: managedIdentifier,
            ownership: .managed
        ))
        guard case .ensureManaged(_, let initialCommand) = ensure else {
            Issue.record("Expected a managed launch intent")
            return
        }
        #expect(initialCommand == "printf ready")
    }

    @Test(arguments: [
        "/usr/bin/tmux",
        "C:\\Tools\\psmux.exe",
        "\\\\server\\share\\zmx.exe"
    ])
    func executableRequiresAValidatedAbsolutePath(_ path: String) throws {
        #expect(try RemoteSessionExecutable(validating: path).path == path)
    }

    @Test(arguments: ["", "tmux", "bin/zmx", "/tmp/bad\npath"])
    func executableRejectsUnsafePaths(_ path: String) {
        #expect(throws: RemoteSessionExecutable.ValidationError.self) {
            try RemoteSessionExecutable(validating: path)
        }
    }

    @Test
    func decodingCannotBypassExecutableValidation() {
        let data = Data(#"{"path":"relative/zmx"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteSessionExecutable.self, from: data)
        }
    }

    @Test
    func identifiersRemainScopedAndAllowFutureBackends() throws {
        let tmux = try RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "shared"
        )
        let zmx = try RemoteSessionIdentifier(
            backendIdentifier: .zmx,
            validating: "shared"
        )
        let futureBackend = try RemoteSessionIdentifier(
            backendIdentifier: RemoteSessionBackendIdentifier(rawValue: "future-backend"),
            validating: "shared"
        )

        #expect(tmux != zmx)
        #expect(Set([tmux, zmx, futureBackend]).count == 3)
    }

    @Test
    func decodingCannotBypassIdentifierValidation() {
        let data = Data(#"{"backendIdentifier":"zmx","rawValue":"bad\nsession"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteSessionIdentifier.self, from: data)
        }
    }

    @Test
    func lifecycleFactoryCreatesIndependentOperationCredentials() {
        let first = RemoteSessionLifecycleEnvelope.make()
        let second = RemoteSessionLifecycleEnvelope.make()

        #expect(first.token != second.token)
        #expect(first.operationID != second.operationID)
    }

    @Test(arguments: [
        ("zmx 0.7.0", RemoteSessionSemanticVersion(major: 0, minor: 7, patch: 0)),
        ("tmux 3.5", RemoteSessionSemanticVersion(major: 3, minor: 5, patch: 0)),
        ("v12.4.9-beta", RemoteSessionSemanticVersion(major: 12, minor: 4, patch: 9))
    ])
    func semanticVersionParsesToolOutput(
        raw: String,
        expected: RemoteSessionSemanticVersion
    ) {
        #expect(RemoteSessionSemanticVersion(raw) == expected)
    }
}
