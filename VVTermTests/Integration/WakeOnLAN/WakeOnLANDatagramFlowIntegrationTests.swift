import Darwin
import Foundation
import Testing
@testable import VVTerm

struct WakeOnLANDatagramFlowIntegrationTests {
    @Test
    func localUDPReceiverGetsTheCompleteDatagram() throws {
        let receiver = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard receiver >= 0 else {
            throw WakeOnLANDatagramIntegrationError.socketCreation(errno)
        }
        defer { Darwin.close(receiver) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard Darwin.setsockopt(
            receiver,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw WakeOnLANDatagramIntegrationError.socketConfiguration(errno)
        }

        var boundAddress = sockaddr_in()
        boundAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        boundAddress.sin_family = sa_family_t(AF_INET)
        boundAddress.sin_port = 0
        boundAddress.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &boundAddress) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    receiver,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw WakeOnLANDatagramIntegrationError.bind(errno)
        }

        var resolvedAddress = sockaddr_in()
        var resolvedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &resolvedAddress) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(receiver, $0, &resolvedLength)
            }
        }
        guard nameResult == 0 else {
            throw WakeOnLANDatagramIntegrationError.addressLookup(errno)
        }

        let expected = WakeOnLANMagicPacket.data(
            for: try WakeOnLANMACAddress("00:11:22:33:44:55")
        )
        try BSDWakeOnLANDatagramSender().send(
            expected,
            to: WakeOnLANIPv4Address("127.0.0.1"),
            port: UInt16(bigEndian: resolvedAddress.sin_port)
        )

        var received = [UInt8](repeating: 0, count: 256)
        let receivedCount = Darwin.recv(receiver, &received, received.count, 0)
        guard receivedCount >= 0 else {
            throw WakeOnLANDatagramIntegrationError.receive(errno)
        }

        #expect(Data(received.prefix(receivedCount)) == expected)
    }
}

private enum WakeOnLANDatagramIntegrationError: Error {
    case socketCreation(Int32)
    case socketConfiguration(Int32)
    case bind(Int32)
    case addressLookup(Int32)
    case receive(Int32)
}
