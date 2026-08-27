import Foundation
import Testing
@testable import VVTerm

struct WakeOnLANMagicPacketTests {
    @Test
    func packetContainsHeaderAndSixteenMACAddressCopies() throws {
        let macAddress = try WakeOnLANMACAddress("00:11:22:33:44:55")
        let bytes = [UInt8](WakeOnLANMagicPacket.data(for: macAddress))

        #expect(bytes.count == 102)
        #expect(Array(bytes.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))

        for copyIndex in 0..<16 {
            let start = 6 + copyIndex * 6
            #expect(Array(bytes[start..<(start + 6)]) == macAddress.bytes)
        }
    }
}
