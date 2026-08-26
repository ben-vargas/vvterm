import Foundation

nonisolated enum ZellijRemoteSessionParser {
    static let maximumOutputBytes = 64 * 1_024
    static let maximumProbeOutputBytes = 8 * 1_024
    static let maximumMutationOutputBytes = 8 * 1_024
    static let maximumSessionCount = 256
    static let maximumAttachedClientCount = 4_096

    struct ProbeResult: Equatable, Sendable {
        let executable: RemoteSessionExecutable
        let rawVersion: String
        let semanticVersion: RemoteSessionSemanticVersion
    }

    private struct Pane: Decodable {
        let isPlugin: Bool
        let isFocused: Bool
        let paneCwd: String?
        let exited: Bool?

        private enum CodingKeys: String, CodingKey {
            case isPlugin = "is_plugin"
            case isFocused = "is_focused"
            case paneCwd = "pane_cwd"
            case exited
        }
    }

    static func parseProbe(_ output: String) -> ProbeResult? {
        guard output.utf8.count <= maximumProbeOutputBytes else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.contains(ZellijRemoteSessionCommandBuilder.availableMarker),
              let pathLine = lines.first(where: {
                  $0.hasPrefix(ZellijRemoteSessionCommandBuilder.pathMarker)
              }) else {
            return nil
        }
        let rawPath = String(
            pathLine.dropFirst(ZellijRemoteSessionCommandBuilder.pathMarker.count)
        )
        guard let executable = try? RemoteSessionExecutable(validating: rawPath),
              let versionLine = lines.first(where: { line in
                  line.split(whereSeparator: \.isWhitespace).first == "zellij"
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

    static func parseSessionList(_ output: String) throws -> [RemoteSessionDescriptor] {
        guard output.utf8.count <= maximumOutputBytes else {
            throw SSHError.outputLimitExceeded
        }
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count <= maximumSessionCount else {
            throw SSHError.outputLimitExceeded
        }

        var seen: Set<RemoteSessionIdentifier> = []
        return try lines.map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  fields[0].hasPrefix("name="),
                  fields[1].hasPrefix("ownership="),
                  fields[2].hasPrefix("clients=") else {
                throw SSHError.unknown("Zellij returned an invalid session list")
            }

            let name = String(fields[0].dropFirst("name=".count))
            guard isValidSessionName(name) else {
                throw SSHError.unknown("Zellij returned invalid session metadata")
            }
            let identifier = try RemoteSessionIdentifier(
                backendIdentifier: .zellij,
                validating: name
            )
            guard seen.insert(identifier).inserted else {
                throw SSHError.unknown("Zellij returned a duplicate session identifier")
            }

            guard let ownership = RemoteSessionOwnership(
                rawValue: String(fields[1].dropFirst("ownership=".count))
            ) else {
                throw SSHError.unknown("Zellij returned invalid session ownership")
            }
            let attachedClientCount = try parseAttachedClientCount(
                fields[2].dropFirst("clients=".count)
            )
            return RemoteSessionDescriptor(
                attachment: RemoteSessionAttachment(
                    identifier: identifier,
                    ownership: ownership
                ),
                attachedClientCount: attachedClientCount,
                containerCount: nil,
                cleanupDisposition: RemoteSessionCleanupDisposition(
                    attachedClientCount: attachedClientCount
                )
            )
        }
    }

    static func parseWorkingDirectory(_ output: String) -> String? {
        guard output.utf8.count <= maximumOutputBytes,
              let data = output.data(using: .utf8),
              let panes = try? JSONDecoder().decode([Pane].self, from: data),
              panes.count <= maximumSessionCount else {
            return nil
        }
        let terminalPanes = panes.filter { !$0.isPlugin && $0.exited != true }
        let candidates = terminalPanes.filter(\.isFocused)
            + terminalPanes.filter { !$0.isFocused }
        return candidates.compactMap(\.paneCwd).first(where: isBoundedAbsolutePath)
    }

    static func isValidSessionName(_ name: String) -> Bool {
        name != "."
            && name != ".."
            && !name.contains("/")
            && (try? RemoteSessionIdentifier(
                backendIdentifier: .zellij,
                validating: name
            )) != nil
    }

    private static func parseAttachedClientCount(
        _ rawValue: Substring
    ) throws -> Int? {
        if rawValue == "?" { return nil }
        guard let count = Int(rawValue),
              (0...maximumAttachedClientCount).contains(count) else {
            throw SSHError.unknown("Zellij returned invalid session metadata")
        }
        return count
    }

    private static func isBoundedAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.utf8.count <= RemoteSessionExecutable.maximumLength
            && path.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
