import Foundation

nonisolated struct WakeOnLANNetworkInterface: Equatable, Sendable {
    let address: WakeOnLANIPv4Address
    let netmask: WakeOnLANIPv4Address
    let isUp: Bool
    let isRunning: Bool
    let supportsBroadcast: Bool
    let isLoopback: Bool
}

nonisolated protocol WakeOnLANInterfaceProviding: Sendable {
    func interfaces() throws -> [WakeOnLANNetworkInterface]
}

nonisolated enum WakeOnLANBroadcastResolver {
    static func destinations(
        for interfaces: [WakeOnLANNetworkInterface]
    ) -> [WakeOnLANIPv4Address] {
        let addresses = interfaces.compactMap { interface -> WakeOnLANIPv4Address? in
            guard interface.isUp,
                  interface.isRunning,
                  interface.supportsBroadcast,
                  !interface.isLoopback else {
                return nil
            }

            let address = interface.address.hostOrderValue
            let netmask = interface.netmask.hostOrderValue
            guard address != 0, netmask != 0, netmask != UInt32.max else {
                return nil
            }

            let hostMask = ~netmask
            guard hostMask & (hostMask &+ 1) == 0 else {
                return nil
            }

            return WakeOnLANIPv4Address(hostOrderValue: address | hostMask)
        }

        return Array(Set(addresses)).sorted {
            $0.hostOrderValue < $1.hostOrderValue
        }
    }
}
