import Darwin
import Foundation

nonisolated protocol WakeOnLANDatagramSending: Sendable {
    func send(_ data: Data, to address: WakeOnLANIPv4Address, port: UInt16) throws
}

nonisolated struct BSDWakeOnLANDatagramSender: WakeOnLANDatagramSending {
    func send(_ data: Data, to address: WakeOnLANIPv4Address, port: UInt16) throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else {
            throw WakeOnLANSendError.socketCreationFailed(code: errno)
        }
        defer { Darwin.close(socketDescriptor) }

        var enabled: Int32 = 1
        guard Darwin.setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_BROADCAST,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw WakeOnLANSendError.broadcastConfigurationFailed(code: errno)
        }

        let destinationString = address.canonicalValue
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(port).bigEndian
        guard inet_pton(
            AF_INET,
            destinationString,
            &destination.sin_addr
        ) == 1 else {
            throw WakeOnLANSendError.destinationEncodingFailed(
                address: destinationString
            )
        }

        let sentByteCount = withUnsafePointer(to: &destination) { destinationPointer in
            destinationPointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { socketAddress in
                data.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return -1 }
                    return Darwin.sendto(
                        socketDescriptor,
                        baseAddress,
                        bytes.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }

        guard sentByteCount >= 0 else {
            let code = errno
            if code == EACCES || code == EPERM {
                throw WakeOnLANSendError.localNetworkAccessDenied
            }
            throw WakeOnLANSendError.datagramSendFailed(
                address: destinationString,
                code: code
            )
        }
        guard sentByteCount == data.count else {
            throw WakeOnLANSendError.incompleteDatagram(
                address: destinationString,
                expected: data.count,
                actual: sentByteCount
            )
        }
    }
}
