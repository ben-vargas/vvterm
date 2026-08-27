import Foundation

nonisolated enum WakeOnLANConfigurationError: Error, Equatable, Sendable {
    case invalidMACAddress
    case invalidIPv4Address
    case invalidPort
}

nonisolated struct WakeOnLANMACAddress: Codable, Hashable, Sendable {
    private let octets: [UInt8]

    init(_ value: String) throws {
        octets = try Self.parse(value)
    }

    var bytes: [UInt8] {
        octets
    }

    var canonicalValue: String {
        octets
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalValue)
    }

    private static func parse(_ value: String) throws -> [UInt8] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [":", "-", "."].filter { trimmed.contains($0) }
        guard separators.count <= 1 else {
            throw WakeOnLANConfigurationError.invalidMACAddress
        }

        let hexPairs: [Substring]
        switch separators.first {
        case ":", "-":
            let separator = Character(separators[0])
            let groups = trimmed.split(
                separator: separator,
                omittingEmptySubsequences: false
            )
            guard groups.count == 6, groups.allSatisfy({ $0.count == 2 }) else {
                throw WakeOnLANConfigurationError.invalidMACAddress
            }
            hexPairs = groups

        case ".":
            let groups = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            guard groups.count == 3, groups.allSatisfy({ $0.count == 4 }) else {
                throw WakeOnLANConfigurationError.invalidMACAddress
            }
            hexPairs = groups.flatMap { group in
                [group.prefix(2), group.suffix(2)]
            }

        case nil:
            guard trimmed.count == 12 else {
                throw WakeOnLANConfigurationError.invalidMACAddress
            }
            hexPairs = stride(from: 0, to: trimmed.count, by: 2).map { offset in
                let start = trimmed.index(trimmed.startIndex, offsetBy: offset)
                let end = trimmed.index(start, offsetBy: 2)
                return trimmed[start..<end]
            }

        default:
            throw WakeOnLANConfigurationError.invalidMACAddress
        }

        let bytes = hexPairs.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else {
            throw WakeOnLANConfigurationError.invalidMACAddress
        }
        return bytes
    }
}

nonisolated struct WakeOnLANIPv4Address: Codable, Hashable, Sendable {
    let hostOrderValue: UInt32

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else {
            throw WakeOnLANConfigurationError.invalidIPv4Address
        }

        var result: UInt32 = 0
        for component in components {
            guard !component.isEmpty,
                  component.utf8.allSatisfy({ (48...57).contains($0) }),
                  let octet = UInt8(component) else {
                throw WakeOnLANConfigurationError.invalidIPv4Address
            }
            result = (result << 8) | UInt32(octet)
        }
        hostOrderValue = result
    }

    init(hostOrderValue: UInt32) {
        self.hostOrderValue = hostOrderValue
    }

    var canonicalValue: String {
        [24, 16, 8, 0]
            .map { String((hostOrderValue >> UInt32($0)) & 0xFF) }
            .joined(separator: ".")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalValue)
    }
}

nonisolated enum WakeOnLANDestination: Codable, Hashable, Sendable {
    nonisolated enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic
        case explicitBroadcast

        var id: String { rawValue }
    }

    case automatic
    case explicitBroadcast(WakeOnLANIPv4Address)

    var mode: Mode {
        switch self {
        case .automatic:
            return .automatic
        case .explicitBroadcast:
            return .explicitBroadcast
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case address
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .automatic:
            self = .automatic
        case .explicitBroadcast:
            self = .explicitBroadcast(
                try container.decode(WakeOnLANIPv4Address.self, forKey: .address)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        if case .explicitBroadcast(let address) = self {
            try container.encode(address, forKey: .address)
        }
    }
}

nonisolated struct WakeOnLANConfiguration: Codable, Hashable, Sendable {
    static let defaultPort: UInt16 = 9

    let macAddress: WakeOnLANMACAddress
    let destination: WakeOnLANDestination
    let port: UInt16

    init(
        macAddress: WakeOnLANMACAddress,
        destination: WakeOnLANDestination = .automatic,
        port: Int = Int(Self.defaultPort)
    ) throws {
        guard let validatedPort = UInt16(exactly: port), validatedPort > 0 else {
            throw WakeOnLANConfigurationError.invalidPort
        }
        self.macAddress = macAddress
        self.destination = destination
        self.port = validatedPort
    }

    private enum CodingKeys: String, CodingKey {
        case macAddress
        case destination
        case port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            macAddress: container.decode(WakeOnLANMACAddress.self, forKey: .macAddress),
            destination: container.decode(WakeOnLANDestination.self, forKey: .destination),
            port: container.decode(Int.self, forKey: .port)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(macAddress, forKey: .macAddress)
        try container.encode(destination, forKey: .destination)
        try container.encode(Int(port), forKey: .port)
    }
}
