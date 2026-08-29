import Foundation
import Testing
@testable import VVTerm

struct ServerIconSelectionTests {
    @Test
    func iconSelectionRoundTripsStableIdentifier() throws {
        let selection = ServerIconSelection.custom(.database)
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(ServerIconSelection.self, from: data)

        #expect(decoded == selection)
        #expect(selection.persistedValue == "custom:database")
    }

    @Test
    func unknownPersistedIconDefaultsToAutomatic() {
        #expect(ServerIconSelection(persistedValue: nil) == .automatic)
        #expect(ServerIconSelection(persistedValue: "custom:future_icon") == .automatic)
    }

    @Test
    func serverDecodingDefaultsMissingIconFields() throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            username: "root"
        )
        let encoded = try JSONEncoder().encode(server)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "iconSelection")
        object.removeValue(forKey: "detectedSystemIdentity")

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Server.self, from: data)

        #expect(decoded.iconSelection == .automatic)
        #expect(decoded.detectedSystemIdentity == nil)
    }

    @Test
    func serverDecodingIgnoresMalformedIconMetadata() throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            username: "root"
        )
        let encoded = try JSONEncoder().encode(server)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["iconSelection"] = ["invalid": true]
        object["detectedSystemIdentity"] = [
            "kind": "future_system",
            "appleHardwareModelIdentifier": "invalid model",
        ]

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Server.self, from: data)

        #expect(decoded.iconSelection == .automatic)
        #expect(decoded.detectedSystemIdentity == nil)
    }

    @Test
    func serverPersistenceStoresIdentityButNoArtworkBytes() throws {
        let model = try #require(AppleHardwareModelIdentifier(rawValue: "MacBookPro18,3"))
        let server = Server(
            workspaceId: UUID(),
            name: "Mac",
            host: "mac.local",
            username: "wiedy",
            iconSelection: .automatic,
            detectedSystemIdentity: RemoteSystemIdentity(
                kind: .macOS,
                displayName: "macOS",
                appleHardwareModelIdentifier: model
            )
        )

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded.detectedSystemIdentity?.appleHardwareModelIdentifier == model)
        #expect(object.keys.allSatisfy { !$0.lowercased().contains("artwork") })
        #expect(object.keys.allSatisfy { !$0.lowercased().contains("image") })
    }
}
