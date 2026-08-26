import CryptoKit
import Foundation

nonisolated enum RemoteSessionManagedIdentifierPolicy {
    enum ValidationError: Error, Equatable {
        case emptyDeviceID
        case generatedIdentifierTooLong
    }

    static let maximumIdentifierLength = 32

    private static let prefix = "vvterm-"
    private static let maximumServerSlugLength = 4
    private static let deviceTokenLength = 10
    private static let sessionTokenLength = 7
    private static let tokenAlphabet = Array("0123456789abcdefghjkmnpqrstvwxyz".utf8)

    static func identifier(
        backendIdentifier: RemoteSessionBackendIdentifier,
        serverName: String,
        deviceID: String,
        entityID: UUID
    ) throws -> RemoteSessionIdentifier {
        guard !deviceID.isEmpty else { throw ValidationError.emptyDeviceID }

        let deviceToken = token("device:\(deviceID)", length: deviceTokenLength)
        let sessionToken = token(
            "session:\(entityID.uuidString.lowercased())",
            length: sessionTokenLength
        )
        let rawValue = "\(prefix)\(serverSlug(serverName))-d\(deviceToken)-s\(sessionToken)"
        guard rawValue.utf8.count <= maximumIdentifierLength else {
            throw ValidationError.generatedIdentifierTooLong
        }
        return try RemoteSessionIdentifier(
            backendIdentifier: backendIdentifier,
            validating: rawValue
        )
    }

    private static func serverSlug(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        let folded = latin
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()

        var slug: [UInt8] = []
        var needsSeparator = false
        for byte in folded.utf8 {
            let isLetter = (97...122).contains(byte)
            let isNumber = (48...57).contains(byte)
            guard isLetter || isNumber else {
                needsSeparator = !slug.isEmpty
                continue
            }
            if needsSeparator {
                guard slug.count + 1 < maximumServerSlugLength else { break }
                slug.append(45)
                needsSeparator = false
            }
            guard slug.count < maximumServerSlugLength else { break }
            slug.append(byte)
        }
        return slug.isEmpty ? "serv" : String(decoding: slug, as: UTF8.self)
    }

    private static func token(_ value: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        var result: [UInt8] = []
        result.reserveCapacity(length)
        var buffer: UInt16 = 0
        var bufferedBitCount = 0

        for byte in digest {
            // The buffer has at most four bits before this shift.
            buffer = (buffer << 8) | UInt16(byte)
            bufferedBitCount += 8
            while bufferedBitCount >= 5 {
                bufferedBitCount -= 5
                let index = Int((buffer >> bufferedBitCount) & 0x1f)
                result.append(tokenAlphabet[index])
                if result.count == length {
                    return String(decoding: result, as: UTF8.self)
                }
            }
            if bufferedBitCount == 0 {
                buffer = 0
            } else {
                buffer &= (UInt16(1) << bufferedBitCount) - 1
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
