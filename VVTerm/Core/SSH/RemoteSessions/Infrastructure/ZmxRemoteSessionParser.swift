import Foundation

nonisolated enum ZmxRemoteSessionParser {
    static let maximumOutputBytes = 32 * 1_024
    static let maximumSessionCount = 256
    static let maximumAttachedClientCount = 4_096

    struct ProbeResult: Equatable, Sendable {
        let executable: RemoteSessionExecutable
        let rawVersion: String
        let semanticVersion: RemoteSessionSemanticVersion
    }

    static func parseProbe(_ output: String) -> ProbeResult? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.contains(ZmxRemoteSessionCommandBuilder.availableMarker),
              let pathLine = lines.first(where: {
                  $0.hasPrefix(ZmxRemoteSessionCommandBuilder.pathMarker)
              }) else {
            return nil
        }
        let rawPath = String(pathLine.dropFirst(ZmxRemoteSessionCommandBuilder.pathMarker.count))
        guard let executable = try? RemoteSessionExecutable(validating: rawPath),
              let versionLine = lines.first(where: { line in
                  line.split(whereSeparator: \.isWhitespace).first == "zmx"
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
        return try lines.map { rawLine in
            let parsed = try parseSessionLine(rawLine)
            let identifier = try RemoteSessionIdentifier(
                backendIdentifier: .zmx,
                validating: parsed.name
            )
            guard seen.insert(identifier).inserted else {
                throw SSHError.unknown("zmx returned a duplicate session identifier")
            }
            return RemoteSessionDescriptor(
                attachment: RemoteSessionAttachment(
                    identifier: identifier,
                    ownership: parsed.ownership
                ),
                attachedClientCount: parsed.attachedClientCount,
                containerCount: nil,
                cleanupDisposition: RemoteSessionCleanupDisposition(
                    attachedClientCount: parsed.attachedClientCount
                )
            )
        }
    }

    private static func parseSessionLine(
        _ line: Substring
    ) throws -> (
        name: String,
        attachedClientCount: Int,
        ownership: RemoteSessionOwnership
    ) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard let nameField = fields.first,
              nameField.hasPrefix("name=") else {
            throw SSHError.unknown("zmx returned invalid session metadata")
        }
        let clientFields = fields.filter { $0.hasPrefix("clients=") }
        guard clientFields.count == 1,
              let clientField = clientFields.first,
              let attachedClientCount = Int(clientField.dropFirst("clients=".count)),
              (0...maximumAttachedClientCount).contains(attachedClientCount) else {
            throw SSHError.unknown("zmx returned invalid client metadata")
        }
        return (
            name: String(nameField.dropFirst("name=".count)),
            attachedClientCount: attachedClientCount,
            ownership: fields.contains(Substring(
                ZmxRemoteSessionCommandBuilder.managedOwnershipLabel
            )) ? .managed : .external
        )
    }

    static func parseWorkingDirectory(
        for identifier: RemoteSessionIdentifier,
        in output: String
    ) -> String? {
        guard identifier.backendIdentifier == .zmx,
              output.utf8.count <= maximumOutputBytes else {
            return nil
        }
        let nameField = "name=\(identifier.rawValue)"
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).first
                == Substring(nameField)
        }) else {
            return nil
        }
        guard let field = line.split(separator: "\t", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("start_dir=") }) else {
            return nil
        }
        let path = String(field.dropFirst("start_dir=".count))
        guard path.hasPrefix("/"),
              (try? RemoteSessionExecutable(validating: path)) != nil else {
            return nil
        }
        return path
    }
}
