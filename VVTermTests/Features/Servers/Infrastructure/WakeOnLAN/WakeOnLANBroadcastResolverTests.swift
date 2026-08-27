import Testing
@testable import VVTerm

struct WakeOnLANBroadcastResolverTests {
    @Test
    func derivesAndDeduplicatesDirectedBroadcastAddresses() throws {
        let interfaces = [
            try makeInterface(address: "192.168.1.42", netmask: "255.255.255.0"),
            try makeInterface(address: "192.168.1.80", netmask: "255.255.255.0"),
            try makeInterface(address: "10.0.0.200", netmask: "255.255.255.128"),
        ]

        let destinations = WakeOnLANBroadcastResolver.destinations(for: interfaces)

        #expect(destinations.map(\.canonicalValue) == [
            "10.0.0.255",
            "192.168.1.255",
        ])
    }

    @Test
    func excludesInactiveLoopbackAndNonBroadcastInterfaces() throws {
        let interfaces = [
            try makeInterface(address: "10.0.0.1", isUp: false),
            try makeInterface(address: "10.0.1.1", isRunning: false),
            try makeInterface(address: "10.0.2.1", supportsBroadcast: false),
            try makeInterface(address: "127.0.0.1", isLoopback: true),
        ]

        #expect(WakeOnLANBroadcastResolver.destinations(for: interfaces).isEmpty)
    }

    @Test
    func excludesInvalidAndHostOnlyNetmasks() throws {
        let interfaces = [
            try makeInterface(address: "10.0.0.1", netmask: "0.0.0.0"),
            try makeInterface(address: "10.0.1.1", netmask: "255.255.255.255"),
            try makeInterface(address: "10.0.2.1", netmask: "255.0.255.0"),
            try makeInterface(address: "0.0.0.0", netmask: "255.255.255.0"),
        ]

        #expect(WakeOnLANBroadcastResolver.destinations(for: interfaces).isEmpty)
    }

    private func makeInterface(
        address: String,
        netmask: String = "255.255.255.0",
        isUp: Bool = true,
        isRunning: Bool = true,
        supportsBroadcast: Bool = true,
        isLoopback: Bool = false
    ) throws -> WakeOnLANNetworkInterface {
        WakeOnLANNetworkInterface(
            name: address,
            address: try WakeOnLANIPv4Address(address),
            netmask: try WakeOnLANIPv4Address(netmask),
            isUp: isUp,
            isRunning: isRunning,
            supportsBroadcast: supportsBroadcast,
            isLoopback: isLoopback
        )
    }
}
