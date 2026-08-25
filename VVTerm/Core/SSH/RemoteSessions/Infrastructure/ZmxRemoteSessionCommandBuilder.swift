import Foundation

nonisolated enum ZmxRemoteSessionCommandBuilder {
    static let availableMarker = "__VVTERM_ZMX_OK__"
    static let missingMarker = "__VVTERM_ZMX_NO__"
    static let pathMarker = "__VVTERM_ZMX_PATH__"

    private static let clearedEnvironment: Set<String> = [
        "ZMX_SESSION",
        "ZMX_SESSION_PREFIX"
    ]

    static func availabilityProbeCommand() -> String {
        let script = """
        \(RemoteTerminalBootstrap.shellPathExport());
        vvtermZmx="$(command -v zmx 2>/dev/null || true)";
        if [ -z "$vvtermZmx" ]; then
          for candidate in /opt/homebrew/bin/zmx /usr/local/bin/zmx /usr/bin/zmx /snap/bin/zmx "$HOME/.local/bin/zmx"; do
            if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then vvtermZmx="$candidate"; break; fi;
          done;
        fi;
        case "$vvtermZmx" in
          /*) ;;
          *) vvtermZmx="" ;;
        esac;
        if [ -n "$vvtermZmx" ] && [ -x "$vvtermZmx" ] && [ ! -d "$vvtermZmx" ]; then
          vvtermZmxVersion="$(env -u ZMX_SESSION -u ZMX_SESSION_PREFIX "$vvtermZmx" version 2>/dev/null | sed -n '1p')";
          if [ -n "$vvtermZmxVersion" ]; then
            printf '%s\n%s%s\n%s\n' '\(availableMarker)' '\(pathMarker)' "$vvtermZmx" "$vvtermZmxVersion";
          else
            printf '%s\n' '\(missingMarker)';
          fi;
        else
          printf '%s\n' '\(missingMarker)';
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func listCommand(runtime: RemoteSessionRuntime) throws -> String {
        try render(arguments: ["list"], runtime: runtime)
    }

    static func launchCommand(
        request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        let identifier = request.attachment.identifier.rawValue
        let list = try shortListCommand(runtime: runtime)
        let exists = exactPresenceExpression(
            listCommand: list,
            identifier: identifier
        )
        let attach = try render(
            arguments: ["attach", identifier],
            workingDirectory: request.workingDirectory == "~"
                ? nil
                : request.workingDirectory,
            runtime: runtime
        )
        let detached = quotedMarker(request.lifecycleEnvelope, .detached)
        let terminated = quotedMarker(request.lifecycleEnvelope, .terminated)
        let creationFailed = quotedMarker(request.lifecycleEnvelope, .creationFailed)
        let attachFailed = quotedMarker(request.lifecycleEnvelope, .attachFailed)

        let runAttach = """
        \(attach)
        vvtermZmxStatus=$?
        if [ "$vvtermZmxStatus" -ne 0 ]; then
          if \(exists); then printf '%s' \(attachFailed); else printf '%s' \(creationFailed); fi
        elif \(exists); then
          printf '%s' \(detached)
        else
          printf '%s' \(terminated)
        fi
        """

        let script: String
        switch request.mode {
        case .attachOrCreate:
            script = runAttach
        case .attachExisting:
            script = """
            if \(exists); then
              \(runAttach)
            else
              printf '%s' \(attachFailed)
            fi
            """
        }
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func presenceProbe(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionPresenceProbe {
        let markerID = UUID().uuidString
        let existsMarker = "__VVTERM_SESSION_EXISTS_\(markerID)__"
        let missingMarker = "__VVTERM_SESSION_MISSING_\(markerID)__"
        let list = try shortListCommand(runtime: runtime)
        let presence = exactPresenceExpression(
            listCommand: list,
            identifier: identifier.rawValue
        )
        let script = """
        if \(presence); then
          printf '%s' \(RemoteTerminalBootstrap.shellQuoted(existsMarker))
        else
          printf '%s' \(RemoteTerminalBootstrap.shellQuoted(missingMarker))
        fi
        """
        return RemoteSessionPresenceProbe(
            command: RemoteTerminalBootstrap.wrapPOSIXShellCommand(script),
            existsMarker: existsMarker,
            missingMarker: missingMarker
        )
    }

    static func killCommand(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        try render(
            arguments: ["kill", identifier.rawValue, "--force"],
            runtime: runtime
        )
    }

    private static func render(
        arguments: [String],
        workingDirectory: String? = nil,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        guard runtime.probe.backendIdentifier == .zmx,
              runtime.probe.shellFamily == .posix else {
            throw SSHError.unknown("zmx requires a POSIX remote shell")
        }
        return try RemoteSessionCommandRenderer.render(
            RemoteSessionCommandPlan(
                executable: runtime.probe.executable,
                arguments: arguments,
                environmentRemovals: clearedEnvironment,
                workingDirectory: workingDirectory
            ),
            for: .posix
        )
    }

    private static func exactPresenceExpression(
        listCommand: String,
        identifier: String
    ) -> String {
        "\(listCommand) | grep -Fqx -- \(RemoteTerminalBootstrap.shellQuoted(identifier))"
    }

    private static func shortListCommand(runtime: RemoteSessionRuntime) throws -> String {
        try render(arguments: ["list", "--short"], runtime: runtime)
    }

    private static func quotedMarker(
        _ envelope: RemoteSessionLifecycleEnvelope,
        _ event: RemoteSessionEvent
    ) -> String {
        RemoteTerminalBootstrap.shellQuoted(
            RemoteSessionLifecycleMarker.sequence(envelope: envelope, event: event)
        )
    }
}
