import Foundation

nonisolated enum ServerIconSelection: Codable, Hashable, Sendable {
    case automatic
    case custom(ServerIconID)

    private static let customPrefix = "custom:"

    var persistedValue: String {
        switch self {
        case .automatic:
            return "automatic"
        case .custom(let iconID):
            return Self.customPrefix + iconID.rawValue
        }
    }

    init(persistedValue: String?) {
        guard
            let persistedValue,
            persistedValue.hasPrefix(Self.customPrefix),
            let iconID = ServerIconID(
                rawValue: String(persistedValue.dropFirst(Self.customPrefix.count))
            )
        else {
            self = .automatic
            return
        }
        self = .custom(iconID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(persistedValue: try? container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }
}
