import Foundation

nonisolated enum ZellijKDLStringEncoder {
    enum EncodingError: Error, Equatable, Sendable {
        case outputTooLong
    }

    static let maximumEncodedByteCount = 32 * 1_024

    static func encode(_ value: String) throws -> String {
        var encoded = "\""
        var byteCount = 1

        for scalar in value.unicodeScalars {
            let fragment = switch scalar.value {
            case 0x08: "\\b"
            case 0x09: "\\t"
            case 0x0A: "\\n"
            case 0x0C: "\\f"
            case 0x0D: "\\r"
            case 0x22: "\\\""
            case 0x5C: "\\\\"
            case 0x00...0x1F, 0x7F:
                "\\u{\(String(scalar.value, radix: 16))}"
            default:
                String(scalar)
            }
            let (nextCount, overflow) = byteCount.addingReportingOverflow(
                fragment.utf8.count
            )
            guard !overflow, nextCount < maximumEncodedByteCount else {
                throw EncodingError.outputTooLong
            }
            encoded.append(fragment)
            byteCount = nextCount
        }

        encoded.append("\"")
        let (finalByteCount, overflow) = byteCount.addingReportingOverflow(1)
        guard !overflow, finalByteCount <= maximumEncodedByteCount else {
            throw EncodingError.outputTooLong
        }
        return encoded
    }
}
