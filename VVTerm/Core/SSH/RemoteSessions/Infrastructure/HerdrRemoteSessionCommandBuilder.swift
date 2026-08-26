import Foundation

nonisolated enum HerdrRemoteSessionCommandBuilder {
    static let availableMarker = "__VVTERM_HERDR_OK__"
    static let missingMarker = "__VVTERM_HERDR_NO__"
    static let pathMarker = "__VVTERM_HERDR_PATH__"
    static let managedOwnershipMarkerPrefix = "__VVTERM_HERDR_MANAGED__:"

    private static let ownershipFileName = ".vvterm-managed"
    private static let maximumLaunchCommandBytes = 64 * 1_024
    private static let clearedEnvironment: Set<String> = [
        "HERDR_ACTIVE_PANE_CWD",
        "HERDR_ACTIVE_PANE_ID",
        "HERDR_ACTIVE_TAB_ID",
        "HERDR_ACTIVE_WORKSPACE_ID",
        "HERDR_BIN_PATH",
        "HERDR_CLIENT_SOCKET_PATH",
        "HERDR_PANE_ID",
        "HERDR_SESSION",
        "HERDR_SOCKET_PATH",
        "HERDR_STARTUP_CWD",
        "HERDR_TAB_ID",
        "HERDR_WORKSPACE_ID"
    ]

    static func availabilityProbeCommand() -> String {
        let script = """
        \(RemoteTerminalBootstrap.shellPathExport());
        vvtermHerdr="$(command -v herdr 2>/dev/null || true)";
        if [ -z "$vvtermHerdr" ]; then
          for candidate in /opt/homebrew/bin/herdr /usr/local/bin/herdr /usr/bin/herdr /snap/bin/herdr "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr"; do
            if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then vvtermHerdr="$candidate"; break; fi;
          done;
        fi;
        case "$vvtermHerdr" in
          /*) ;;
          *) vvtermHerdr="" ;;
        esac;
        if [ -n "$vvtermHerdr" ] && [ -x "$vvtermHerdr" ] && [ ! -d "$vvtermHerdr" ]; then
          vvtermHerdrVersion="$(env -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH "$vvtermHerdr" --version 2>/dev/null | sed -n '1p')";
          if [ -n "$vvtermHerdrVersion" ]; then
            printf '%s\n%s%s\n%s\n' '\(availableMarker)' '\(pathMarker)' "$vvtermHerdr" "$vvtermHerdrVersion";
          else
            printf '%s\n' '__VVTERM_HERDR_INVALID__';
          fi;
        else
          printf '%s\n' '\(missingMarker)';
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func listCommand(runtime: RemoteSessionRuntime) throws -> String {
        let list = try render(arguments: ["session", "list", "--json"], runtime: runtime)
        let script = """
        \(list) 2>/dev/null || exit $?
        printf '\n'
        \(configRootScript())
        for vvtermHerdrMarker in "$vvtermHerdrConfigRoot"/sessions/*/\(ownershipFileName); do
          [ -f "$vvtermHerdrMarker" ] || continue
          vvtermHerdrSessionDirectory="${vvtermHerdrMarker%/\(ownershipFileName)}"
          vvtermHerdrSessionName="${vvtermHerdrSessionDirectory##*/}"
          printf '%s%s\n' '\(managedOwnershipMarkerPrefix)' "$vvtermHerdrSessionName"
        done
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func currentPaneCommand(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        try requireValid(identifier)
        return try render(
            arguments: ["--session", identifier.rawValue, "pane", "current"],
            runtime: runtime
        )
    }

    static func launchCommand(
        request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        let attachment = request.intent.attachment
        let identifier = attachment.identifier
        try requireValid(identifier)
        if case .ensureManaged(_, let initialCommand) = request.intent,
           initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw SSHError.managedStartupCommandUnsupported("Herdr")
        }

        let workingDirectory = request.workingDirectory == "~"
            ? nil
            : request.workingDirectory
        let attach = try render(
            arguments: ["session", "attach", identifier.rawValue],
            workingDirectory: workingDirectory,
            runtime: runtime
        )
        let status = try statusCommand(identifier: identifier, runtime: runtime)
        let attached = quotedMarker(request.lifecycleEnvelope, .attached)
        let detached = quotedMarker(request.lifecycleEnvelope, .detached)
        let terminated = quotedMarker(request.lifecycleEnvelope, .terminated)
        let creationFailed = quotedMarker(request.lifecycleEnvelope, .creationFailed)
        let attachFailed = quotedMarker(request.lifecycleEnvelope, .attachFailed)

        let ownershipPreparation: String
        switch request.intent {
        case .attach(let existingAttachment):
            let expectedOwnership = existingAttachment.ownership == .managed
                ? "managed"
                : "external"
            ownershipPreparation = """
            vvtermHerdrReadOwnership
            [ "$vvtermHerdrOwnership" = '\(expectedOwnership)' ] || {
              printf '%s' \(attachFailed)
              exit 0
            }
            """
        case .ensureManaged:
            ownershipPreparation = """
            vvtermHerdrReadOwnership
            if [ "$vvtermHerdrOwnership" = missing ]; then
              if (umask 077; mkdir -p "$vvtermHerdrConfigRoot/sessions") \
                 && (umask 077; mkdir "$vvtermHerdrSessionDirectory") 2>/dev/null; then
                if (umask 077; : > "$vvtermHerdrOwnershipMarker") \
                   && chmod 600 "$vvtermHerdrOwnershipMarker"; then
                  vvtermHerdrOwnership=managed
                  vvtermHerdrCreated=1
                else
                  rmdir "$vvtermHerdrSessionDirectory" 2>/dev/null || true
                  vvtermHerdrOwnership=missing
                fi
              else
                vvtermHerdrReadOwnership
              fi
            fi
            [ "$vvtermHerdrOwnership" = managed ] || {
              printf '%s' \(creationFailed)
              exit 0
            }
            """
        }

        let script = """
        \(configRootScript())
        vvtermHerdrSessionName=\(RemoteTerminalBootstrap.shellQuoted(identifier.rawValue))
        vvtermHerdrCreated=0
        if [ "$vvtermHerdrSessionName" = default ]; then
          vvtermHerdrSessionDirectory="$vvtermHerdrConfigRoot"
        else
          vvtermHerdrSessionDirectory="$vvtermHerdrConfigRoot/sessions/$vvtermHerdrSessionName"
        fi
        vvtermHerdrOwnershipMarker="$vvtermHerdrSessionDirectory/\(ownershipFileName)"
        vvtermHerdrReadOwnership() {
          if [ "$vvtermHerdrSessionName" = default ]; then
            vvtermHerdrOwnership=external
          elif [ -f "$vvtermHerdrOwnershipMarker" ]; then
            vvtermHerdrOwnership=managed
          elif [ -d "$vvtermHerdrSessionDirectory" ]; then
            vvtermHerdrOwnership=external
          else
            vvtermHerdrOwnership=missing
          fi
        }
        \(ownershipPreparation)
        printf '%s' \(attached)
        \(attach)
        vvtermHerdrAttachStatus=$?
        if [ "$vvtermHerdrAttachStatus" -ne 0 ]; then
          if [ "$vvtermHerdrCreated" -eq 1 ]; then
            printf '%s' \(creationFailed)
          else
            printf '%s' \(attachFailed)
          fi
          exit 0
        fi
        \(sessionStatusClassificationScript(statusCommand: status))
        case "$vvtermHerdrRuntimeState" in
          running) printf '%s' \(detached) ;;
          stopped) printf '%s' \(terminated) ;;
          *) printf '%s' \(attachFailed) ;;
        esac
        """
        guard script.utf8.count <= maximumLaunchCommandBytes else {
            throw SSHError.outputLimitExceeded
        }
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func presenceProbe(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionPresenceProbe {
        try requireValid(identifier)
        let markerID = UUID().uuidString
        let existsMarker = "__VVTERM_SESSION_EXISTS_\(markerID)__"
        let missingMarker = "__VVTERM_SESSION_MISSING_\(markerID)__"
        let status = try statusCommand(identifier: identifier, runtime: runtime)
        let script = """
        \(sessionStatusClassificationScript(statusCommand: status))
        if [ "$vvtermHerdrRuntimeState" = running ]; then
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

    static func stopCommand(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        try requireValid(identifier)
        return try render(
            arguments: ["session", "stop", identifier.rawValue, "--json"],
            runtime: runtime
        )
    }

    static func deleteCommand(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        try requireValid(identifier)
        guard identifier.rawValue != "default" else {
            throw SSHError.unknown("Herdr does not delete its default session")
        }
        return try render(
            arguments: ["session", "delete", identifier.rawValue, "--json"],
            runtime: runtime
        )
    }

    static func sessionStatusClassificationScript(statusCommand: String) -> String {
        """
        vvtermHerdrRuntimeState=unknown
        vvtermHerdrStatusPayload="$(
          (\(statusCommand) 2>/dev/null
           printf '__VVTERM_HERDR_STATUS__%s\n' "$?") | head -c 512
        )"
        case "$vvtermHerdrStatusPayload" in
          'status: running
        __VVTERM_HERDR_STATUS__0') vvtermHerdrRuntimeState=running ;;
          'status: not running
        __VVTERM_HERDR_STATUS__0') vvtermHerdrRuntimeState=stopped ;;
        esac
        """
    }

    private static func statusCommand(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        try render(
            arguments: ["--session", identifier.rawValue, "status", "server"],
            runtime: runtime
        )
    }

    private static func configRootScript() -> String {
        """
        if [ "${XDG_CONFIG_HOME+x}" = x ]; then
          vvtermHerdrConfigRoot="$XDG_CONFIG_HOME/herdr"
        else
          vvtermHerdrConfigRoot="$HOME/.config/herdr"
        fi
        """
    }

    private static func render(
        arguments: [String],
        workingDirectory: String? = nil,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        guard runtime.probe.backendIdentifier == .herdr,
              runtime.probe.shellFamily == .posix else {
            throw SSHError.unknown("Herdr requires a POSIX remote shell")
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

    private static func requireValid(_ identifier: RemoteSessionIdentifier) throws {
        guard identifier.backendIdentifier == .herdr,
              HerdrRemoteSessionParser.isValidSessionName(identifier.rawValue) else {
            throw SSHError.unknown("Invalid Herdr session identifier")
        }
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
