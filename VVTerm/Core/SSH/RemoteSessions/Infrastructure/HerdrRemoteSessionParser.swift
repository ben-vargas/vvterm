import Foundation

nonisolated enum HerdrRemoteSessionParser {
    static let maximumOutputBytes = 64 * 1_024
    static let maximumProbeOutputBytes = 8 * 1_024
    static let maximumMutationOutputBytes = 16 * 1_024
    static let maximumSessionCount = 256
    static let maximumSessionNameBytes = 64

    struct ProbeResult: Equatable, Sendable {
        let executable: RemoteSessionExecutable
        let rawVersion: String
        let semanticVersion: RemoteSessionSemanticVersion
    }

    private struct SessionList: Decodable {
        let sessions: [Session]
    }

    private struct Session: Decodable {
        let name: String
        let `default`: Bool
        let running: Bool
        let socketPath: String
        let sessionDirectory: String

        private enum CodingKeys: String, CodingKey {
            case name
            case `default`
            case running
            case socketPath = "socket_path"
            case sessionDirectory = "session_dir"
        }
    }

    private struct CurrentPaneResponse: Decodable {
        struct Result: Decodable {
            struct Pane: Decodable {
                let cwd: String
                let foregroundCwd: String?

                private enum CodingKeys: String, CodingKey {
                    case cwd
                    case foregroundCwd = "foreground_cwd"
                }
            }

            let pane: Pane
        }

        let result: Result
    }

    static func parseProbe(_ output: String) -> ProbeResult? {
        guard output.utf8.count <= maximumProbeOutputBytes else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.contains(HerdrRemoteSessionCommandBuilder.availableMarker),
              let pathLine = lines.first(where: {
                  $0.hasPrefix(HerdrRemoteSessionCommandBuilder.pathMarker)
              }) else {
            return nil
        }
        let rawPath = String(
            pathLine.dropFirst(HerdrRemoteSessionCommandBuilder.pathMarker.count)
        )
        guard let executable = try? RemoteSessionExecutable(validating: rawPath),
              let versionLine = lines.first(where: { line in
                  line.split(whereSeparator: \.isWhitespace).first == "herdr"
              }),
              let semanticVersion = RemoteSessionSemanticVersion(versionLine) else {
            return nil
        }
        return ProbeResult(
            executable: executable,
            rawVersion: versionLine,
            semanticVersion: semanticVersion
        )
    }

    static func parseSessionList(
        _ output: String,
        scope: RemoteSessionListScope
    ) throws -> [RemoteSessionDescriptor] {
        guard output.utf8.count <= maximumOutputBytes else {
            throw SSHError.outputLimitExceeded
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let json = lines.first,
              let payload = try? JSONDecoder().decode(
                  SessionList.self,
                  from: Data(json.utf8)
              ),
              payload.sessions.count <= maximumSessionCount else {
            throw SSHError.unknown("Herdr returned an invalid session list")
        }

        var managedNames: Set<String> = []
        for line in lines.dropFirst() {
            guard line.hasPrefix(
                HerdrRemoteSessionCommandBuilder.managedOwnershipMarkerPrefix
            ) else {
                throw SSHError.unknown("Herdr returned invalid ownership metadata")
            }
            let name = String(line.dropFirst(
                HerdrRemoteSessionCommandBuilder.managedOwnershipMarkerPrefix.count
            ))
            guard name != "default",
                  isValidSessionName(name),
                  managedNames.insert(name).inserted,
                  managedNames.count <= maximumSessionCount else {
                throw SSHError.unknown("Herdr returned invalid ownership metadata")
            }
        }

        var seen: Set<RemoteSessionIdentifier> = []
        let descriptors = try payload.sessions.map { session in
            guard isValidSessionName(session.name),
                  session.default == (session.name == "default"),
                  isBoundedAbsolutePath(session.socketPath),
                  isBoundedAbsolutePath(session.sessionDirectory) else {
                throw SSHError.unknown("Herdr returned invalid session metadata")
            }
            let identifier = try RemoteSessionIdentifier(
                backendIdentifier: .herdr,
                validating: session.name
            )
            guard seen.insert(identifier).inserted else {
                throw SSHError.unknown("Herdr returned a duplicate session identifier")
            }
            let ownership: RemoteSessionOwnership = managedNames.contains(session.name)
                ? .managed
                : .external
            return RemoteSessionDescriptor(
                attachment: RemoteSessionAttachment(
                    identifier: identifier,
                    ownership: ownership
                ),
                attachedClientCount: nil,
                containerCount: nil,
                cleanupDisposition: session.running ? .unknown : .safeToDelete
            )
        }
        guard managedNames.isSubset(of: Set(payload.sessions.map(\.name))) else {
            throw SSHError.unknown("Herdr returned stale ownership metadata")
        }

        switch scope {
        case .userVisible:
            return descriptors
        case .managedCleanup:
            return descriptors.filter { $0.attachment.ownership == .managed }
        }
    }

    static func parseWorkingDirectory(_ output: String) -> String? {
        guard output.utf8.count <= maximumOutputBytes,
              let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(
                  CurrentPaneResponse.self,
                  from: data
              ) else {
            return nil
        }
        let candidates = [response.result.pane.foregroundCwd, response.result.pane.cwd]
            .compactMap { $0 }
        return candidates.first(where: isBoundedAbsolutePath)
    }

    static func isValidSessionName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard !bytes.isEmpty,
              bytes.count <= maximumSessionNameBytes,
              name != ".",
              name != ".." else {
            return false
        }
        return bytes.allSatisfy { byte in
            (65...90).contains(byte)
                || (97...122).contains(byte)
                || (48...57).contains(byte)
                || byte == 46
                || byte == 95
                || byte == 45
        }
    }

    private static func isBoundedAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.utf8.count <= RemoteSessionExecutable.maximumLength
            && path.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
