import Foundation

nonisolated struct AppleHardwareModelIdentifier: RawRepresentable, Codable, Hashable, Sendable {
    enum Family: String, Codable, Hashable, Sendable {
        case macBook
        case macMini
        case macStudio
        case iMac
        case macPro
        case unknown
    }

    static let maximumByteCount = 128

    let rawValue: String

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= Self.maximumByteCount else {
            return nil
        }
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == ",")
        }) else {
            return nil
        }

        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let product = components[0]
        let revision = components[1]
        guard
            product.first?.isLetter == true,
            product.contains(where: \Character.isNumber),
            !revision.isEmpty,
            revision.allSatisfy(\Character.isNumber)
        else {
            return nil
        }

        self.rawValue = value
    }

    var family: Family {
        if rawValue.hasPrefix("MacBook") {
            return .macBook
        }
        if rawValue.hasPrefix("Macmini") || Self.macMiniModelIdentifiers.contains(rawValue) {
            return .macMini
        }
        if Self.macStudioModelIdentifiers.contains(rawValue) {
            return .macStudio
        }
        if rawValue.hasPrefix("iMac") {
            return .iMac
        }
        if rawValue.hasPrefix("MacPro") {
            return .macPro
        }
        return .unknown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Apple hardware model identifier"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static let macMiniModelIdentifiers: Set<String> = [
        "Mac16,10",
    ]

    private static let macStudioModelIdentifiers: Set<String> = [
        "Mac13,1",
        "Mac13,2",
        "Mac14,13",
        "Mac14,14",
    ]
}
