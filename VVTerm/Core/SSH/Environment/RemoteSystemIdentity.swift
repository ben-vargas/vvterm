import Foundation

nonisolated enum RemoteSystemKind: String, Codable, CaseIterable, Hashable, Sendable {
    case linux
    case ubuntu
    case debian
    case fedora
    case redHat = "red_hat"
    case arch
    case alpine
    case openSUSE = "opensuse"
    case nixOS = "nixos"
    case macOS = "macos"
    case freeBSD = "freebsd"
    case openBSD = "openbsd"
    case netBSD = "netbsd"
    case windows
    case unknown
}

nonisolated struct RemoteSystemIdentity: Codable, Hashable, Sendable {
    private static let maximumDisplayNameByteCount = 96

    private enum CodingKeys: String, CodingKey {
        case kind
        case displayName
        case appleHardwareModelIdentifier
    }

    let kind: RemoteSystemKind
    let displayName: String?
    let appleHardwareModelIdentifier: AppleHardwareModelIdentifier?

    init(
        kind: RemoteSystemKind,
        displayName: String? = nil,
        appleHardwareModelIdentifier: AppleHardwareModelIdentifier? = nil
    ) {
        self.kind = kind
        self.displayName = Self.sanitizedDisplayName(displayName)
        self.appleHardwareModelIdentifier = kind == .macOS
            ? appleHardwareModelIdentifier
            : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(RemoteSystemKind.self, forKey: .kind),
            displayName: try? container.decode(String.self, forKey: .displayName),
            appleHardwareModelIdentifier: try? container.decode(
                AppleHardwareModelIdentifier.self,
                forKey: .appleHardwareModelIdentifier
            )
        )
    }

    private static func sanitizedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }

        let printable = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let normalized = String(printable)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        var result = ""
        var remainingBytes = maximumDisplayNameByteCount
        for character in normalized {
            let byteCount = String(character).utf8.count
            guard byteCount <= remainingBytes else { break }
            result.append(character)
            remainingBytes -= byteCount
        }
        return result.isEmpty ? nil : result
    }
}
