import Foundation
import Testing
@testable import VVTerm

struct ServerRemoteSessionPersistenceTests {
    @Test
    func tmuxRemainsTheDefaultBackend() {
        let server = Server(
            workspaceId: UUID(),
            name: "Default",
            host: "default.example.com",
            username: "root"
        )

        #expect(server.remoteSessionBackendIdentifier == .tmux)
    }

    @Test
    func legacyTmuxFieldsReadOnceAndCurrentWritesDoNotRepeatThem() throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Legacy",
            host: "legacy.example.com",
            username: "root"
        )
        let encoded = try JSONEncoder().encode(server)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "remoteSessionEnabledOverride")
        object.removeValue(forKey: "remoteSessionBackendIdentifier")
        object.removeValue(forKey: "remoteSessionStartupBehaviorOverride")
        object["tmuxEnabledOverride"] = false
        object["tmuxStartupBehaviorOverride"] = "skipTmux"

        let migrated = try JSONDecoder().decode(
            Server.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(migrated.remoteSessionEnabledOverride == false)
        #expect(migrated.remoteSessionBackendIdentifier == .tmux)
        #expect(migrated.remoteSessionStartupBehaviorOverride == .plainShell)

        let rewritten = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated))
                as? [String: Any]
        )
        #expect(rewritten["remoteSessionEnabledOverride"] as? Bool == false)
        #expect(rewritten["remoteSessionBackendIdentifier"] as? String == "tmux")
        #expect(rewritten["remoteSessionStartupBehaviorOverride"] as? String == "plainShell")
        #expect(rewritten["tmuxEnabledOverride"] == nil)
        #expect(rewritten["tmuxStartupBehaviorOverride"] == nil)
    }

    @Test
    func currentBackendFieldsRoundTripWithoutExtraConfigurationState() throws {
        let server = Server(
            workspaceId: UUID(),
            name: "zmx",
            host: "zmx.example.com",
            username: "root",
            remoteSessionEnabledOverride: true,
            remoteSessionBackendIdentifier: .zmx,
            remoteSessionStartupBehaviorOverride: .createManaged
        )

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        let text = String(decoding: data, as: UTF8.self)

        #expect(decoded == server)
        #expect(text.contains("remoteSessionBackendIdentifier"))
        #expect(!text.contains("configurationVersion"))
        #expect(!text.contains("compatibility"))
    }
}
