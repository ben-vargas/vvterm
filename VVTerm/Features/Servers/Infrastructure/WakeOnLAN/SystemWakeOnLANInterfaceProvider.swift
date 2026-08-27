import Darwin
import Foundation

nonisolated struct SystemWakeOnLANInterfaceProvider: WakeOnLANInterfaceProviding {
    func interfaces() throws -> [WakeOnLANNetworkInterface] {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else {
            throw WakeOnLANSendError.interfaceEnumerationFailed(code: errno)
        }
        defer { freeifaddrs(interfacePointer) }

        var result: [WakeOnLANNetworkInterface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            defer { pointer = entry.ifa_next }

            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask,
                  let name = String(validatingCString: entry.ifa_name) else {
                continue
            }

            let ipv4 = address.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1
            ) { $0.pointee }
            let mask = netmask.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1
            ) { $0.pointee }
            let flags = Int32(entry.ifa_flags)

            result.append(
                WakeOnLANNetworkInterface(
                    name: name,
                    address: WakeOnLANIPv4Address(
                        hostOrderValue: UInt32(bigEndian: ipv4.sin_addr.s_addr)
                    ),
                    netmask: WakeOnLANIPv4Address(
                        hostOrderValue: UInt32(bigEndian: mask.sin_addr.s_addr)
                    ),
                    isUp: flags & IFF_UP != 0,
                    isRunning: flags & IFF_RUNNING != 0,
                    supportsBroadcast: flags & IFF_BROADCAST != 0,
                    isLoopback: flags & IFF_LOOPBACK != 0
                )
            )
        }
        return result
    }
}
