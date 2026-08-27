import Foundation

nonisolated enum WakeOnLANMagicPacket {
    static let byteCount = 102

    static func data(for macAddress: WakeOnLANMACAddress) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 6)
        bytes.reserveCapacity(byteCount)
        for _ in 0..<16 {
            bytes.append(contentsOf: macAddress.bytes)
        }
        return Data(bytes)
    }
}
