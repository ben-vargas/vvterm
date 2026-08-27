import Foundation
import Testing
@testable import VVTerm

struct WakeOnLANConfigurationTests {
    @Test
    func acceptedMACAddressFormatsUseOneCanonicalValue() throws {
        let inputs = [
            "AA:BB:CC:DD:EE:FF",
            "aa-bb-cc-dd-ee-ff",
            "aabb.ccdd.eeff",
            "aabbccddeeff",
            "  aa:bb:cc:dd:ee:ff  ",
        ]

        for input in inputs {
            let address = try WakeOnLANMACAddress(input)
            #expect(address.canonicalValue == "AA:BB:CC:DD:EE:FF")
            #expect(address.bytes == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        }
    }

    @Test
    func invalidMACAddressesAreRejected() {
        let inputs = [
            "",
            "AA:BB:CC:DD:EE",
            "AA:BB:CC:DD:EE:FFF",
            "AA:BB-CC:DD:EE:FF",
            "AA:BB:CC:DD:EE:GG",
            "AABB.CCDD.EE",
            "AABBCCDDEEFF00",
            "00:00:00:00:00:00",
            "01:11:22:33:44:55",
            "FF:FF:FF:FF:FF:FF",
        ]

        for input in inputs {
            #expect(throws: WakeOnLANConfigurationError.invalidMACAddress) {
                try WakeOnLANMACAddress(input)
            }
        }
    }

    @Test
    func IPv4AddressValidationIsStrictAndCanonical() throws {
        #expect(try WakeOnLANIPv4Address("192.168.1.255").canonicalValue == "192.168.1.255")
        #expect(try WakeOnLANIPv4Address(" 10.0.0.1 ").canonicalValue == "10.0.0.1")

        let invalidAddresses = [
            "",
            "192.168.1",
            "192.168.1.256",
            "192.168..1",
            "192.168.1.-1",
            "192.168.1.a",
            "192.168.1.1.1",
        ]
        for address in invalidAddresses {
            #expect(throws: WakeOnLANConfigurationError.invalidIPv4Address) {
                try WakeOnLANIPv4Address(address)
            }
        }
    }

    @Test
    func configurationRoundTripsAndIgnoresOldAdvancedValues() throws {
        let configuration = WakeOnLANConfiguration(
            macAddress: try WakeOnLANMACAddress("00:11:22:33:44:55")
        )
        let encoded = try JSONEncoder().encode(configuration)
        #expect(
            try JSONDecoder().decode(WakeOnLANConfiguration.self, from: encoded)
                == configuration
        )

        let oldData = Data(
            #"{"macAddress":"00:11:22:33:44:55","destination":{"mode":"automatic"},"port":9}"#.utf8
        )
        #expect(
            try JSONDecoder().decode(WakeOnLANConfiguration.self, from: oldData)
                == configuration
        )
    }

    @Test
    func serverPersistenceMigratesMissingWakeFactsToDefaults() throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Legacy",
            host: "legacy.example.test",
            username: "root"
        )
        let data = try JSONEncoder().encode(server)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["wakeOnLANConfiguration"] == nil)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.wakeOnLANConfiguration == nil)
        #expect(!decoded.autoWakeOnLANEnabled)
    }

    @Test
    func serverPersistenceRoundTripsConfiguration() throws {
        let configuration = WakeOnLANConfiguration(
            macAddress: try WakeOnLANMACAddress("00:11:22:33:44:55")
        )
        let server = Server(
            workspaceId: UUID(),
            name: "Wakeable",
            host: "wakeable.example.test",
            username: "root",
            wakeOnLANConfiguration: configuration,
            autoWakeOnLANEnabled: true
        )

        let decoded = try JSONDecoder().decode(
            Server.self,
            from: JSONEncoder().encode(server)
        )

        #expect(decoded == server)
        #expect(decoded.wakeOnLANConfiguration == configuration)
        #expect(decoded.autoWakeOnLANEnabled)
    }
}
