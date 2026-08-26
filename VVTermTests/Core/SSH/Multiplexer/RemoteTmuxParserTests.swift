import Foundation
import Testing
@testable import VVTerm

struct RemoteTmuxParserTests {
    @Test
    func parseWhitespaceFormatFromRealTmuxOutput() {
        let output = """
        aizen-00F43729-7E11-4731-ADFE-603A766AFCF6 1 1
        aizen-7922A0D1-DD37-4530-866F-30C60B0E9C26 0 1
        """

        let sessions = RemoteTmuxParser.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0].name == "aizen-00F43729-7E11-4731-ADFE-603A766AFCF6")
        #expect(sessions[0].attachedClients == 1)
        #expect(sessions[0].windowCount == 1)
        #expect(!sessions[0].name.hasSuffix(" 1 1"))
        #expect(sessions[1].name == "aizen-7922A0D1-DD37-4530-866F-30C60B0E9C26")
        #expect(sessions[1].attachedClients == 0)
    }

    @Test
    func parseLiteralEscapedTabsFormat() {
        let output = "prod\\t2\\t3\ndev\\t0\\t1\n"

        let sessions = RemoteTmuxParser.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0] == session("prod", attachedClients: 2, windowCount: 3))
        #expect(sessions[1] == session("dev", attachedClients: 0, windowCount: 1))
    }

    @Test
    func parseTwoFieldFormatDefaultsWindowCountToOne() {
        let output = """
        qa 1
        local 0
        """

        let sessions = RemoteTmuxParser.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0] == session("qa", attachedClients: 1, windowCount: 1))
        #expect(sessions[1] == session("local", attachedClients: 0, windowCount: 1))
    }

    @Test
    func parseBooleanAttachedFormatFromPsmuxOutput() {
        let output = """
        restored true 1
        detached false 2
        """

        let sessions = RemoteTmuxParser.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0] == session("restored", attachedClients: 1, windowCount: 1))
        #expect(sessions[1] == session("detached", attachedClients: 0, windowCount: 2))
    }

    @Test
    func parseLegacyListSessionsFormatWhenEnabled() {
        let output = """
        ops: 2 windows (created Sat Feb 14 10:00:00 2026) [80x24] (attached)
        api: 1 windows (created Sat Feb 14 10:01:00 2026) [80x24]
        """

        let sessions = RemoteTmuxParser.parseSessionListOutput(output, allowLegacy: true)
        #expect(sessions.count == 2)
        #expect(sessions[0] == session("ops", attachedClients: 1, windowCount: 2))
        #expect(sessions[1] == session("api", attachedClients: 0, windowCount: 1))
    }

    @Test
    func ownershipRequiresTheExplicitSessionOptionField() {
        let sessions = RemoteTmuxParser.parseSessionListOutput(
            "vvterm-user\t0\t1\t\nmanaged\t0\t1\t1\n",
            allowLegacy: false
        )

        #expect(Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0.ownership) }) == [
            "vvterm-user": .external,
            "managed": .managed
        ])
    }

    @Test
    func sortPrefersAttachedThenWindowCountThenName() {
        let output = """
        zeta 1 1
        alpha 1 3
        beta 1 3
        gamma 0 9
        """

        let sessions = RemoteTmuxParser.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.map { $0.name } == ["alpha", "beta", "zeta", "gamma"])
    }

    private func session(
        _ name: String,
        attachedClients: Int,
        windowCount: Int
    ) -> RemoteTmuxSession {
        RemoteTmuxSession(
            name: name,
            attachedClients: attachedClients,
            windowCount: windowCount,
            ownership: .external
        )
    }

}
