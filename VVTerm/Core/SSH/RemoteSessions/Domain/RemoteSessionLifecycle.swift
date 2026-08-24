import Foundation

nonisolated enum RemoteSessionEvent: String, Codable, CaseIterable, Hashable, Sendable {
    case attached
    case detached
    case terminated
    case creationFailed
    case attachFailed
    case transportInterrupted
    case observationAmbiguous
}

nonisolated struct RemoteSessionLifecycleEnvelope: Codable, Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidToken
    }

    static let maximumTokenLength = 128

    private enum CodingKeys: String, CodingKey {
        case token
        case operationID
    }

    let token: String
    let operationID: UUID

    init(token: String, operationID: UUID) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !token.isEmpty,
              token.utf8.count <= Self.maximumTokenLength,
              token.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ValidationError.invalidToken
        }
        self.token = token
        self.operationID = operationID
    }

    static func make() -> Self {
        try! Self(token: UUID().uuidString, operationID: UUID())
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try container.decode(String.self, forKey: .token)
        let operationID = try container.decode(UUID.self, forKey: .operationID)
        do {
            try self.init(token: token, operationID: operationID)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .token,
                in: container,
                debugDescription: "Invalid remote session lifecycle token"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(operationID, forKey: .operationID)
    }
}

nonisolated enum RemoteSessionLifecycleMarker {
    private static let prefix = "\u{001B}]777;vvterm-session-v1;"
    private static let bellTerminator = "\u{0007}"
    private static let stringTerminator = "\u{001B}\\"

    enum Terminator: Sendable {
        case bell
        case string
    }

    static func sequence(
        envelope: RemoteSessionLifecycleEnvelope,
        event: RemoteSessionEvent,
        terminator: Terminator = .bell
    ) -> String {
        let suffix = switch terminator {
        case .bell: bellTerminator
        case .string: stringTerminator
        }
        return "\(prefix)\(envelope.token);\(envelope.operationID.uuidString.lowercased());\(event.rawValue)\(suffix)"
    }
}

nonisolated struct RemoteSessionLifecycleStreamParser: Sendable {
    struct Result: Equatable, Sendable {
        let output: Data
        let events: [RemoteSessionEvent]
    }

    private let markers: [(event: RemoteSessionEvent, data: Data)]
    private var pending = Data()

    init(envelope: RemoteSessionLifecycleEnvelope) {
        markers = RemoteSessionEvent.allCases
            .filter { event in
                switch event {
                case .attached, .detached, .terminated, .creationFailed, .attachFailed:
                    true
                case .transportInterrupted, .observationAmbiguous:
                    false
                }
            }
            .flatMap { event in
                [
                    (
                        event,
                        Data(RemoteSessionLifecycleMarker.sequence(
                            envelope: envelope,
                            event: event,
                            terminator: .bell
                        ).utf8)
                    ),
                    (
                        event,
                        Data(RemoteSessionLifecycleMarker.sequence(
                            envelope: envelope,
                            event: event,
                            terminator: .string
                        ).utf8)
                    )
                ]
            }
    }

    mutating func consume(_ data: Data) -> Result {
        pending.append(data)
        var output = Data()
        var events: [RemoteSessionEvent] = []

        while let match = earliestMarkerMatch() {
            output.append(pending[..<match.range.lowerBound])
            pending.removeSubrange(..<match.range.upperBound)
            events.append(match.event)
        }

        let suffixLength = longestPossibleMarkerPrefixSuffixLength()
        let outputEnd = pending.index(pending.endIndex, offsetBy: -suffixLength)
        output.append(pending[..<outputEnd])
        pending.removeSubrange(..<outputEnd)

        return Result(output: output, events: events)
    }

    mutating func finish() -> Data {
        defer { pending.removeAll(keepingCapacity: false) }
        return pending
    }

    private func earliestMarkerMatch() -> (event: RemoteSessionEvent, range: Range<Data.Index>)? {
        markers.compactMap { marker in
            pending.range(of: marker.data).map { (marker.event, $0) }
        }.min { lhs, rhs in
            lhs.1.lowerBound < rhs.1.lowerBound
        }
    }

    private func longestPossibleMarkerPrefixSuffixLength() -> Int {
        let maximumMarkerLength = markers.lazy.map(\.data.count).max() ?? 0
        let maximumLength = min(pending.count, maximumMarkerLength)
        guard maximumLength > 0 else { return 0 }

        for length in stride(from: maximumLength, through: 1, by: -1) {
            let suffixStart = pending.index(pending.endIndex, offsetBy: -length)
            let suffix = pending[suffixStart...]
            if markers.contains(where: { $0.data.prefix(length).elementsEqual(suffix) }) {
                return length
            }
        }
        return 0
    }
}
