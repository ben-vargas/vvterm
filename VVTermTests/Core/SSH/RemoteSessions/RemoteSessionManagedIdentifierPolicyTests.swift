import Foundation
import Testing
@testable import VVTerm

struct RemoteSessionManagedIdentifierPolicyTests {
    private let entityID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!

    @Test
    func identifierKeepsAReadableServerNameAndFiftyDeviceIdentityBits() throws {
        let identifier = try RemoteSessionManagedIdentifierPolicy.identifier(
            backendIdentifier: .zmx,
            serverName: "Prod API",
            deviceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID
        )
        let components = identifier.rawValue.split(separator: "-")

        #expect(identifier.rawValue.hasPrefix("vvterm-prod-d"))
        #expect(identifier.rawValue.utf8.count <= 32)
        try #require(components.count >= 4)
        let deviceComponent = components[components.count - 2]
        let sessionComponent = components[components.count - 1]
        #expect(deviceComponent.first == "d")
        #expect(deviceComponent.count == 11)
        #expect(sessionComponent.first == "s")
        #expect(sessionComponent.count == 8)
    }

    @Test
    func everyBackendUsesTheSameRawName() throws {
        let backends: [RemoteSessionBackendIdentifier] = [
            .tmux,
            .zmx,
            RemoteSessionBackendIdentifier(rawValue: "herdr"),
            RemoteSessionBackendIdentifier(rawValue: "zellij")
        ]
        let identifiers = try backends.map { backend in
            try RemoteSessionManagedIdentifierPolicy.identifier(
                backendIdentifier: backend,
                serverName: "Prod API",
                deviceID: "device-a",
                entityID: entityID
            )
        }

        #expect(Set(identifiers.map(\.rawValue)).count == 1)
        #expect(Set(identifiers.map(\.backendIdentifier)) == Set(backends))
    }

    @Test
    func identifierIsStableUniqueAndDeviceScoped() throws {
        let first = try identifier(deviceID: "device-a", entityID: entityID)
        let repeated = try identifier(deviceID: "device-a", entityID: entityID)
        let otherDevice = try identifier(deviceID: "device-b", entityID: entityID)
        let otherSession = try identifier(
            deviceID: "device-a",
            entityID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        )

        #expect(first == repeated)
        #expect(first != otherDevice)
        #expect(first != otherSession)
        #expect(RemoteSessionManagedIdentifierPolicy.isManagedIdentifier(
            first,
            deviceID: "device-a"
        ))
        #expect(!RemoteSessionManagedIdentifierPolicy.isManagedIdentifier(
            first,
            deviceID: "device-b"
        ))
    }

    @Test
    func serverSlugIsReadableBoundedAndNeverEmpty() throws {
        let long = try identifier(
            serverName: "This Is A Very Long Production API Server"
        )
        let accented = try identifier(serverName: "Résumé Web")
        let punctuation = try identifier(serverName: "---")

        #expect(long.rawValue.hasPrefix("vvterm-this-d"))
        #expect(long.rawValue.utf8.count == 32)
        #expect(accented.rawValue.hasPrefix("vvterm-resu-d"))
        #expect(punctuation.rawValue.hasPrefix("vvterm-serv-d"))
    }

    @Test
    func emptyDeviceIDIsRejected() {
        #expect(throws: RemoteSessionManagedIdentifierPolicy.ValidationError.emptyDeviceID) {
            try identifier(deviceID: "")
        }
    }

    private func identifier(
        serverName: String = "Prod API",
        deviceID: String = "device-a",
        entityID: UUID? = nil
    ) throws -> RemoteSessionIdentifier {
        try RemoteSessionManagedIdentifierPolicy.identifier(
            backendIdentifier: .tmux,
            serverName: serverName,
            deviceID: deviceID,
            entityID: entityID ?? self.entityID
        )
    }
}
