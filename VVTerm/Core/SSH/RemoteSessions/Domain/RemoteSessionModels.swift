import Foundation

nonisolated struct RemoteSessionBackendIdentifier: RawRepresentable, Codable, Hashable, Sendable {
    static let herdr = Self(rawValue: "herdr")
    static let tmux = Self(rawValue: "tmux")
    static let zellij = Self(rawValue: "zellij")
    static let zmx = Self(rawValue: "zmx")

    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

nonisolated struct RemoteSessionBackendMetadata: Hashable, Sendable {
    enum Installation: Hashable, Sendable {
        case automatic
        case documentation(URL)
    }

    let identifier: RemoteSessionBackendIdentifier
    let displayName: String
    let installation: Installation
    let managedStartupCommandSupport: ManagedStartupCommandSupport
}

nonisolated enum ManagedStartupCommandSupport: Hashable, Sendable {
    case supported
    case unsupported
}

nonisolated struct RemoteSessionThemeStyle: Hashable, Sendable {
    let name: String
    let modeStyle: String
}

nonisolated struct RemoteSessionSemanticVersion: Codable, Comparable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: \.isNumber) else { return nil }
        let versionPrefix = trimmed[start...].prefix { $0.isNumber || $0 == "." }
        let components = versionPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count),
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = components.count == 3 ? Int(components[2]) : 0,
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

nonisolated struct RemoteSessionExecutable: Codable, Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case empty
        case notAbsolute
        case tooLong
        case containsControlCharacters
    }

    static let maximumLength = 4_096

    private enum CodingKeys: String, CodingKey {
        case path
    }

    let path: String

    init(validating path: String) throws {
        guard !path.isEmpty else { throw ValidationError.empty }
        guard path.utf8.count <= Self.maximumLength else { throw ValidationError.tooLong }
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ValidationError.containsControlCharacters
        }
        let isPOSIXAbsolute = path.hasPrefix("/")
        let isWindowsDriveAbsolute: Bool
        if path.count >= 3 {
            let drive = path[path.startIndex]
            let colon = path[path.index(path.startIndex, offsetBy: 1)]
            let separator = path[path.index(path.startIndex, offsetBy: 2)]
            isWindowsDriveAbsolute = drive.isLetter
                && colon == ":"
                && (separator == "\\" || separator == "/")
        } else {
            isWindowsDriveAbsolute = false
        }
        let isWindowsUNC = path.hasPrefix("\\\\")
        guard isPOSIXAbsolute || isWindowsDriveAbsolute || isWindowsUNC else {
            throw ValidationError.notAbsolute
        }
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        do {
            try self.init(validating: path)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: container,
                debugDescription: "Invalid remote session executable path"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
    }
}

nonisolated struct RemoteSessionProbe: Codable, Hashable, Sendable {
    let backendIdentifier: RemoteSessionBackendIdentifier
    let executable: RemoteSessionExecutable
    let implementationVariant: String
    let rawVersion: String
    let semanticVersion: RemoteSessionSemanticVersion?
    let shellFamily: RemoteShellFamily
    let shellExecutable: String?
}

nonisolated enum RemoteSessionProbeFailure: Hashable, Sendable {
    case cancelled
    case timeout
    case disconnected
    case transport(String)
    case channelOpenFailed
    case shellRequestFailed
    case invalidResponse
    case commandFailed(String)

    var retryError: Error {
        switch self {
        case .cancelled:
            CancellationError()
        case .timeout:
            SSHError.timeout
        case .disconnected:
            SSHError.notConnected
        case .transport(let message):
            SSHError.socketError(message)
        case .channelOpenFailed:
            SSHError.channelOpenFailed
        case .shellRequestFailed:
            SSHError.shellRequestFailed
        case .invalidResponse:
            SSHError.unknown("Unable to verify the remote session backend")
        case .commandFailed(let message):
            SSHError.unknown(message)
        }
    }

    static func resolve(_ error: Error) -> Self {
        if error is CancellationError {
            return .cancelled
        }
        guard let sshError = error as? SSHError else {
            return .commandFailed(error.localizedDescription)
        }
        switch sshError {
        case .timeout:
            return .timeout
        case .notConnected:
            return .disconnected
        case .connectionFailed(let message), .socketError(let message):
            return .transport(message)
        case .channelOpenFailed:
            return .channelOpenFailed
        case .shellRequestFailed:
            return .shellRequestFailed
        default:
            return .commandFailed(sshError.localizedDescription)
        }
    }

    var logDescription: String {
        switch self {
        case .cancelled: "cancelled"
        case .timeout: "timeout"
        case .disconnected: "disconnected"
        case .transport: "transport failure"
        case .channelOpenFailed: "channel open failure"
        case .shellRequestFailed: "shell request failure"
        case .invalidResponse: "invalid response"
        case .commandFailed: "command failure"
        }
    }
}

nonisolated enum RemoteSessionAvailability: Hashable, Sendable {
    case unsupportedEnvironment
    case available(RemoteSessionProbe)
    case confirmedMissing
    case incompatible(RemoteSessionProbe)
    case indeterminate(RemoteSessionProbeFailure)
}

nonisolated struct RemoteSessionRuntime: Codable, Hashable, Sendable {
    let probe: RemoteSessionProbe

    var backendIdentifier: RemoteSessionBackendIdentifier {
        probe.backendIdentifier
    }
}

nonisolated struct RemoteSessionIdentifier: Codable, Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case empty
        case tooLong
        case containsControlCharacters
    }

    static let maximumRawValueLength = 128

    private enum CodingKeys: String, CodingKey {
        case backendIdentifier
        case rawValue
    }

    let backendIdentifier: RemoteSessionBackendIdentifier
    let rawValue: String

    init(
        backendIdentifier: RemoteSessionBackendIdentifier,
        validating rawValue: String
    ) throws {
        guard !rawValue.isEmpty else { throw ValidationError.empty }
        guard rawValue.utf8.count <= Self.maximumRawValueLength else {
            throw ValidationError.tooLong
        }
        guard rawValue.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ValidationError.containsControlCharacters
        }
        self.backendIdentifier = backendIdentifier
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let backendIdentifier = try container.decode(
            RemoteSessionBackendIdentifier.self,
            forKey: .backendIdentifier
        )
        let rawValue = try container.decode(String.self, forKey: .rawValue)
        do {
            try self.init(backendIdentifier: backendIdentifier, validating: rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .rawValue,
                in: container,
                debugDescription: "Invalid remote session identifier"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backendIdentifier, forKey: .backendIdentifier)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

nonisolated enum RemoteSessionOwnership: String, Codable, Hashable, Sendable {
    case managed
    case external
}

nonisolated enum RemoteSessionStartupBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case createManaged
    case ask
    case plainShell

    var id: String { rawValue }
    init?(persistedRawValue: String) {
        switch persistedRawValue {
        case Self.createManaged.rawValue, "vvtermManaged":
            self = .createManaged
        case Self.ask.rawValue, "askEveryTime":
            self = .ask
        case Self.plainShell.rawValue, "skipTmux":
            self = .plainShell
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(persistedRawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown remote session startup behavior"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct RemoteSessionAttachment: Codable, Hashable, Sendable {
    let identifier: RemoteSessionIdentifier
    let ownership: RemoteSessionOwnership
}

nonisolated struct RemoteSessionDescriptor: Codable, Hashable, Identifiable, Sendable {
    let attachment: RemoteSessionAttachment
    let attachedClientCount: Int?
    let containerCount: Int?
    let cleanupDisposition: RemoteSessionCleanupDisposition

    var id: RemoteSessionIdentifier { attachment.identifier }
}

nonisolated enum RemoteSessionListScope: Hashable, Sendable {
    case userVisible
    case managedCleanup
}

nonisolated enum RemoteSessionLaunchIntent: Hashable, Sendable {
    case attach(RemoteSessionAttachment)
    case ensureManaged(
        identifier: RemoteSessionIdentifier,
        initialCommand: String?
    )

    var attachment: RemoteSessionAttachment {
        switch self {
        case .attach(let attachment):
            return attachment
        case .ensureManaged(let identifier, _):
            return RemoteSessionAttachment(
                identifier: identifier,
                ownership: .managed
            )
        }
    }

}

nonisolated struct RemoteSessionLaunchRequest: Hashable, Sendable {
    let intent: RemoteSessionLaunchIntent
    let workingDirectory: String
    let lifecycleEnvelope: RemoteSessionLifecycleEnvelope
    let transport: ShellTransport
    let themeStyle: RemoteSessionThemeStyle

    var attachment: RemoteSessionAttachment { intent.attachment }
}

nonisolated struct RemoteSessionPresenceProbe: Codable, Hashable, Sendable {
    let command: String
    let existsMarker: String
    let missingMarker: String

    func sessionExists(in output: String) -> Bool? {
        let reportsExists = output.contains(existsMarker)
        let reportsMissing = output.contains(missingMarker)
        switch (reportsExists, reportsMissing) {
        case (true, false): return true
        case (false, true): return false
        case (false, false), (true, true): return nil
        }
    }
}

nonisolated struct RemoteSessionBackendLaunchPlan: Hashable, Sendable {
    let command: String
    let presenceProbe: RemoteSessionPresenceProbe
    let preparationCommand: String?
    let shellProfile: RemoteShellProfile?

    init(command: String, presenceProbe: RemoteSessionPresenceProbe, preparationCommand: String? = nil,
         shellProfile: RemoteShellProfile? = nil) {
        self.command = command
        self.presenceProbe = presenceProbe
        self.preparationCommand = preparationCommand
        self.shellProfile = shellProfile
    }
}
