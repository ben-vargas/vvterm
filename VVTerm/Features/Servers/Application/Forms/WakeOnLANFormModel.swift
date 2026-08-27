import Foundation

nonisolated struct WakeOnLANFormModel: Equatable, Sendable {
    var isEnabled: Bool
    var macAddress: String
    var destinationMode: WakeOnLANDestination.Mode
    var broadcastAddress: String
    var port: String

    init(configuration: WakeOnLANConfiguration? = nil) {
        isEnabled = configuration != nil
        macAddress = configuration?.macAddress.canonicalValue ?? ""
        destinationMode = configuration?.destination.mode ?? .automatic
        if case .explicitBroadcast(let address) = configuration?.destination {
            broadcastAddress = address.canonicalValue
        } else {
            broadcastAddress = ""
        }
        port = String(configuration?.port ?? WakeOnLANConfiguration.defaultPort)
    }

    var isValid: Bool {
        !isEnabled || persistedConfiguration != nil
    }

    var hasValidMACAddress: Bool {
        !isEnabled || (try? WakeOnLANMACAddress(macAddress)) != nil
    }

    var hasValidBroadcastAddress: Bool {
        !isEnabled
            || destinationMode == .automatic
            || (try? WakeOnLANIPv4Address(broadcastAddress)) != nil
    }

    var hasValidPort: Bool {
        !isEnabled || Self.validPort(port) != nil
    }

    var persistedConfiguration: WakeOnLANConfiguration? {
        guard isEnabled,
              let macAddress = try? WakeOnLANMACAddress(macAddress),
              let port = Self.validPort(port) else {
            return nil
        }

        let destination: WakeOnLANDestination
        switch destinationMode {
        case .automatic:
            destination = .automatic
        case .explicitBroadcast:
            guard let address = try? WakeOnLANIPv4Address(broadcastAddress) else {
                return nil
            }
            destination = .explicitBroadcast(address)
        }

        return try? WakeOnLANConfiguration(
            macAddress: macAddress,
            destination: destination,
            port: port
        )
    }

    private static func validPort(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(trimmed),
              (1...65_535).contains(port) else {
            return nil
        }
        return port
    }
}
