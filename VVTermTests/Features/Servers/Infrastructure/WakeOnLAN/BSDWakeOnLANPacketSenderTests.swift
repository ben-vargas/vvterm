import Foundation
import Testing
@testable import VVTerm

struct BSDWakeOnLANPacketSenderTests {
    @Test
    func automaticModeSendsTheMagicPacketToEachDirectedBroadcast() async throws {
        let interfaces = [
            try makeInterface(address: "192.168.1.40", netmask: "255.255.255.0"),
            try makeInterface(address: "10.0.0.140", netmask: "255.255.255.128"),
        ]
        let datagramSender = RecordingWakeOnLANDatagramSender()
        let sender = makeSender(
            interfaces: interfaces,
            datagramSender: datagramSender
        )
        let configuration = try makeConfiguration(port: 7)

        let receipt = try await sender.send(configuration: configuration)
        let calls = datagramSender.calls

        #expect(receipt.destinations.map(\.canonicalValue) == [
            "10.0.0.255",
            "192.168.1.255",
        ])
        #expect(calls.map { $0.address.canonicalValue } == [
            "10.0.0.255",
            "192.168.1.255",
        ])
        #expect(calls.allSatisfy { $0.port == 7 })
        #expect(calls.allSatisfy { $0.data.count == WakeOnLANMagicPacket.byteCount })
    }

    @Test
    func explicitModeDoesNotEnumerateInterfaces() async throws {
        let destination = try WakeOnLANIPv4Address("172.16.0.255")
        let datagramSender = RecordingWakeOnLANDatagramSender()
        let sender = BSDWakeOnLANPacketSender(
            interfaceProvider: FailingWakeOnLANInterfaceProvider(),
            datagramSender: datagramSender
        )
        let configuration = try WakeOnLANConfiguration(
            macAddress: WakeOnLANMACAddress("00:11:22:33:44:55"),
            destination: .explicitBroadcast(destination),
            port: 9
        )

        let receipt = try await sender.send(configuration: configuration)

        #expect(receipt.destinations == [destination])
        #expect(datagramSender.calls.map(\.address) == [destination])
    }

    @Test
    func oneSuccessfulInterfaceMakesAutomaticSendSucceed() async throws {
        let first = try WakeOnLANIPv4Address("10.0.0.255")
        let datagramSender = RecordingWakeOnLANDatagramSender(
            failingAddresses: [first]
        )
        let sender = makeSender(
            interfaces: [
                try makeInterface(address: "10.0.0.1"),
                try makeInterface(address: "192.168.1.1"),
            ],
            datagramSender: datagramSender
        )

        let receipt = try await sender.send(configuration: makeConfiguration())

        #expect(receipt.destinations.map(\.canonicalValue) == ["192.168.1.255"])
        #expect(datagramSender.calls.count == 2)
    }

    @Test
    func automaticModeFailsWithoutAnEligibleInterface() async throws {
        let sender = makeSender(
            interfaces: [],
            datagramSender: RecordingWakeOnLANDatagramSender()
        )

        await #expect(throws: WakeOnLANSendError.noEligibleNetworkInterface) {
            try await sender.send(configuration: makeConfiguration())
        }
    }

    private func makeSender(
        interfaces: [WakeOnLANNetworkInterface],
        datagramSender: RecordingWakeOnLANDatagramSender
    ) -> BSDWakeOnLANPacketSender {
        BSDWakeOnLANPacketSender(
            interfaceProvider: FixtureWakeOnLANInterfaceProvider(interfaces: interfaces),
            datagramSender: datagramSender
        )
    }

    private func makeConfiguration(
        port: Int = 9
    ) throws -> WakeOnLANConfiguration {
        try WakeOnLANConfiguration(
            macAddress: WakeOnLANMACAddress("00:11:22:33:44:55"),
            port: port
        )
    }

    private func makeInterface(
        address: String,
        netmask: String = "255.255.255.0"
    ) throws -> WakeOnLANNetworkInterface {
        WakeOnLANNetworkInterface(
            name: address,
            address: try WakeOnLANIPv4Address(address),
            netmask: try WakeOnLANIPv4Address(netmask),
            isUp: true,
            isRunning: true,
            supportsBroadcast: true,
            isLoopback: false
        )
    }
}

private struct FixtureWakeOnLANInterfaceProvider: WakeOnLANInterfaceProviding {
    let interfacesValue: [WakeOnLANNetworkInterface]

    init(interfaces: [WakeOnLANNetworkInterface]) {
        interfacesValue = interfaces
    }

    func interfaces() throws -> [WakeOnLANNetworkInterface] {
        interfacesValue
    }
}

private struct FailingWakeOnLANInterfaceProvider: WakeOnLANInterfaceProviding {
    func interfaces() throws -> [WakeOnLANNetworkInterface] {
        throw WakeOnLANSendError.interfaceEnumerationFailed(code: 1)
    }
}

private final class RecordingWakeOnLANDatagramSender: WakeOnLANDatagramSending, @unchecked Sendable {
    struct Call: Sendable {
        let data: Data
        let address: WakeOnLANIPv4Address
        let port: UInt16
    }

    private let lock = NSLock()
    private let failingAddresses: Set<WakeOnLANIPv4Address>
    private var storedCalls: [Call] = []

    init(failingAddresses: Set<WakeOnLANIPv4Address> = []) {
        self.failingAddresses = failingAddresses
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func send(
        _ data: Data,
        to address: WakeOnLANIPv4Address,
        port: UInt16
    ) throws {
        lock.lock()
        storedCalls.append(Call(data: data, address: address, port: port))
        lock.unlock()

        if failingAddresses.contains(address) {
            throw WakeOnLANSendError.datagramSendFailed(
                address: address.canonicalValue,
                code: 1
            )
        }
    }
}
