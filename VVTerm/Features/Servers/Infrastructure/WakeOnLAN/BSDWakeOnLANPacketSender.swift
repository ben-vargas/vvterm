import Darwin
import Foundation

nonisolated struct BSDWakeOnLANPacketSender: WakeOnLANPacketSending {
    private static let wakePort: UInt16 = 9

    private let interfaceProvider: any WakeOnLANInterfaceProviding
    private let datagramSender: any WakeOnLANDatagramSending

    init(
        interfaceProvider: any WakeOnLANInterfaceProviding,
        datagramSender: any WakeOnLANDatagramSending
    ) {
        self.interfaceProvider = interfaceProvider
        self.datagramSender = datagramSender
    }

    func send(
        configuration: WakeOnLANConfiguration
    ) async throws -> WakeOnLANSendReceipt {
        try await Task.detached(priority: .userInitiated) {
            try sendSynchronously(configuration: configuration)
        }.value
    }

    private func sendSynchronously(
        configuration: WakeOnLANConfiguration
    ) throws -> WakeOnLANSendReceipt {
        let destinations = try destinations()
        let packet = WakeOnLANMagicPacket.data(for: configuration.macAddress)

        var sentDestinations: [WakeOnLANIPv4Address] = []
        var firstFailure: WakeOnLANSendError?
        for destination in destinations {
            do {
                try datagramSender.send(
                    packet,
                    to: destination,
                    port: Self.wakePort
                )
                sentDestinations.append(destination)
            } catch let error as WakeOnLANSendError {
                if firstFailure == nil {
                    firstFailure = error
                }
            } catch {
                if firstFailure == nil {
                    firstFailure = .datagramSendFailed(
                        address: destination.canonicalValue,
                        code: EIO
                    )
                }
            }
        }

        guard !sentDestinations.isEmpty else {
            throw firstFailure ?? WakeOnLANSendError.noEligibleNetworkInterface
        }
        return WakeOnLANSendReceipt(destinations: sentDestinations)
    }

    private func destinations() throws -> [WakeOnLANIPv4Address] {
        let interfaces: [WakeOnLANNetworkInterface]
        do {
            interfaces = try interfaceProvider.interfaces()
        } catch let error as WakeOnLANSendError {
            throw error
        } catch {
            throw WakeOnLANSendError.interfaceEnumerationFailed(code: EIO)
        }
        let destinations = WakeOnLANBroadcastResolver.destinations(for: interfaces)
        guard !destinations.isEmpty else {
            throw WakeOnLANSendError.noEligibleNetworkInterface
        }
        return destinations
    }
}
