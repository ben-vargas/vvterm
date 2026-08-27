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
    func malformedMACAddressesAreRejected() {
        let inputs = [
            "",
            "AA:BB:CC:DD:EE",
            "AA:BB:CC:DD:EE:FFF",
            "AA:BB-CC:DD:EE:FF",
            "AA:BB:CC:DD:EE:GG",
            "AABB.CCDD.EE",
            "AABBCCDDEEFF00",
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
    func configurationValidatesPortsAndRoundTrips() throws {
        let macAddress = try WakeOnLANMACAddress("00:11:22:33:44:55")
        let destination = WakeOnLANDestination.explicitBroadcast(
            try WakeOnLANIPv4Address("10.20.30.255")
        )

        #expect(throws: WakeOnLANConfigurationError.invalidPort) {
            try WakeOnLANConfiguration(
                macAddress: macAddress,
                destination: destination,
                port: 0
            )
        }
        #expect(throws: WakeOnLANConfigurationError.invalidPort) {
            try WakeOnLANConfiguration(
                macAddress: macAddress,
                destination: destination,
                port: 65_536
            )
        }

        let configuration = try WakeOnLANConfiguration(
            macAddress: macAddress,
            destination: destination,
            port: 65_535
        )
        let encoded = try JSONEncoder().encode(configuration)

        #expect(try JSONDecoder().decode(WakeOnLANConfiguration.self, from: encoded) == configuration)
    }

    @Test
    func serverPersistenceMigratesMissingConfigurationToDisabled() throws {
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
        #expect(try JSONDecoder().decode(Server.self, from: data).wakeOnLANConfiguration == nil)
    }

    @Test
    func serverPersistenceRoundTripsConfiguration() throws {
        let configuration = try WakeOnLANConfiguration(
            macAddress: WakeOnLANMACAddress("00:11:22:33:44:55"),
            destination: .automatic,
            port: 9
        )
        let server = Server(
            workspaceId: UUID(),
            name: "Wakeable",
            host: "wakeable.example.test",
            username: "root",
            wakeOnLANConfiguration: configuration
        )

        let decoded = try JSONDecoder().decode(
            Server.self,
            from: JSONEncoder().encode(server)
        )

        #expect(decoded == server)
        #expect(decoded.wakeOnLANConfiguration == configuration)
    }
}
