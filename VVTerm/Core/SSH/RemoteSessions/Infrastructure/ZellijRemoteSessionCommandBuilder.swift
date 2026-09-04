import Foundation

nonisolated enum ZellijRemoteSessionCommandBuilder {
    static let availableMarker = "__VVTERM_ZELLIJ_OK__"
    static let missingMarker = "__VVTERM_ZELLIJ_NO__"
    static let pathMarker = "__VVTERM_ZELLIJ_PATH__"

    private static let maximumLaunchCommandBytes = 96 * 1_024
    private static let clearedEnvironment: Set<String> = [
        "ZELLIJ",
        "ZELLIJ_AUTO_ATTACH",
        "ZELLIJ_AUTO_EXIT",
        "ZELLIJ_PANE_ID",
        "ZELLIJ_SESSION_NAME"
    ]

    static func availabilityProbeCommand() -> String {
        let script = """
        \(RemoteTerminalBootstrap.shellPathExport());
        vvtermZellij="$(command -v zellij 2>/dev/null || true)";
        if [ -z "$vvtermZellij" ]; then
          for candidate in /opt/homebrew/bin/zellij /usr/local/bin/zellij /usr/bin/zellij /snap/bin/zellij "$HOME/.local/bin/zellij" "$HOME/.cargo/bin/zellij"; do
            if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then vvtermZellij="$candidate"; break; fi;
          done;
        fi;
        case "$vvtermZellij" in
          /*) ;;
          *) vvtermZellij="" ;;
        esac;
        if [ -n "$vvtermZellij" ] && [ -x "$vvtermZellij" ] && [ ! -d "$vvtermZellij" ]; then
          vvtermZellijVersion="$(env -u ZELLIJ -u ZELLIJ_AUTO_ATTACH -u ZELLIJ_AUTO_EXIT -u ZELLIJ_PANE_ID -u ZELLIJ_SESSION_NAME "$vvtermZellij" --version 2>/dev/null | sed -n '1p')";
          if [ -n "$vvtermZellijVersion" ]; then
            printf '%s\n%s%s\n%s\n' '\(availableMarker)' '\(pathMarker)' "$vvtermZellij" "$vvtermZellijVersion";
          else
            printf '%s\n' '__VVTERM_ZELLIJ_INVALID__';
          fi;
        else
          printf '%s\n' '\(missingMarker)';
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func listCommand(
        scope: RemoteSessionListScope,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        let namespace: ZellijSocketNamespace = switch scope {
        case .userVisible: .user
        case .managedCleanup: .managed
        }
        let ownership = switch scope {
        case .userVisible: RemoteSessionOwnership.external.rawValue
        case .managedCleanup: RemoteSessionOwnership.managed.rawValue
        }
        let list = try render(
            arguments: ["list-sessions", "--short", "--no-formatting"],
            runtime: runtime
        )
        let executable = try render(arguments: [], runtime: runtime)
        let ownershipFilter = scope == .managedCleanup
            ? """
              vvtermZellijOwnershipMarker="$vvtermZellijOwnershipRoot/$vvtermZellijSession"
              [ -f "$vvtermZellijOwnershipMarker" ] \
                && [ ! -L "$vvtermZellijOwnershipMarker" ] || continue
            """
            : ":"

        let script = """
        \(namespace.setupScript)
        \(scope == .managedCleanup ? managedMetadataSetupScript() : "")
        umask 077
        vvtermZellijListFile="$(mktemp "${TMPDIR:-/tmp}/vvterm-zellij-list.XXXXXX")" || exit 1
        vvtermZellijProbeFile="$(mktemp "${TMPDIR:-/tmp}/vvterm-zellij-probe.XXXXXX")" || {
          rm -f "$vvtermZellijListFile"
          exit 1
        }
        vvtermZellijStatusFile="$(mktemp "${TMPDIR:-/tmp}/vvterm-zellij-status.XXXXXX")" || {
          rm -f "$vvtermZellijListFile" "$vvtermZellijProbeFile"
          exit 1
        }
        chmod 600 "$vvtermZellijListFile" "$vvtermZellijProbeFile" \
          "$vvtermZellijStatusFile" || {
          rm -f "$vvtermZellijListFile" "$vvtermZellijProbeFile" \
            "$vvtermZellijStatusFile"
          exit 1
        }
        vvtermZellijCleanupListFiles() {
          rm -f "$vvtermZellijListFile" "$vvtermZellijProbeFile" \
            "$vvtermZellijStatusFile"
        }
        vvtermZellijCapture() {
          vvtermZellijCaptureOutput="$1"
          vvtermZellijCaptureStatusFile="$2"
          shift 2
          : >"$vvtermZellijCaptureOutput" \
            && : >"$vvtermZellijCaptureStatusFile" || return 1
          ("$@"; printf '%s\n' "$?" >"$vvtermZellijCaptureStatusFile") 2>&1 \
            | head -c \(ZellijRemoteSessionParser.maximumOutputBytes + 1) \
              >"$vvtermZellijCaptureOutput"
          [ "$?" -eq 0 ] || return 1
          vvtermZellijCapturedBytes="$(wc -c <"$vvtermZellijCaptureOutput" | tr -d '[:space:]')"
          case "$vvtermZellijCapturedBytes" in ''|*[!0-9]*) return 1 ;; esac
          [ "$vvtermZellijCapturedBytes" -le \(ZellijRemoteSessionParser.maximumOutputBytes) ] \
            || return 1
          vvtermZellijCapturedStatus="$(sed -n '1p' "$vvtermZellijCaptureStatusFile")"
          case "$vvtermZellijCapturedStatus" in ''|*[!0-9]*) return 1 ;; esac
          [ "$vvtermZellijCapturedStatus" -le 255 ] || return 1
        }
        trap 'vvtermZellijCleanupListFiles; exit 1' HUP INT TERM
        trap vvtermZellijCleanupListFiles EXIT

        vvtermZellijCapture "$vvtermZellijListFile" "$vvtermZellijStatusFile" \
          \(list) || exit 1
        vvtermZellijListStatus="$vvtermZellijCapturedStatus"
        if [ "$vvtermZellijListStatus" -eq 1 ] \
           && [ "$(cat "$vvtermZellijListFile")" = 'No active zellij sessions found.' ]; then
          : >"$vvtermZellijListFile"
        elif [ "$vvtermZellijListStatus" -ne 0 ]; then
          exit 1
        fi

        vvtermZellijCandidateCount=0
        while IFS= read -r vvtermZellijSession || [ -n "$vvtermZellijSession" ]; do
          [ -n "$vvtermZellijSession" ] || continue
          vvtermZellijCandidateCount=$((vvtermZellijCandidateCount + 1))
          [ "$vvtermZellijCandidateCount" -le \(ZellijRemoteSessionParser.maximumSessionCount) ] || exit 1
          case "$vvtermZellijSession" in '.'|'..'|*/*) exit 1 ;; esac
          vvtermZellijNameBytes="$(printf '%s' "$vvtermZellijSession" | wc -c | tr -d '[:space:]')"
          case "$vvtermZellijNameBytes" in ''|*[!0-9]*) exit 1 ;; esac
          [ "$vvtermZellijNameBytes" -le \(RemoteSessionIdentifier.maximumRawValueLength) ] || exit 1
          vvtermZellijCleanName="$(printf '%s' "$vvtermZellijSession" | LC_ALL=C tr -d '[:cntrl:]')"
          [ "$vvtermZellijCleanName" = "$vvtermZellijSession" ] || exit 1

          \(ownershipFilter)
          vvtermZellijCapture "$vvtermZellijProbeFile" "$vvtermZellijStatusFile" \
            \(executable) '--session' "$vvtermZellijSession" \
              'action' 'list-panes' '--json' || exit 1
          vvtermZellijProbeStatus="$vvtermZellijCapturedStatus"
          [ "$vvtermZellijProbeStatus" -eq 0 ] || continue

          if vvtermZellijCapture "$vvtermZellijProbeFile" "$vvtermZellijStatusFile" \
               \(executable) '--session' "$vvtermZellijSession" \
                 'action' 'list-clients' \
             && [ "$vvtermZellijCapturedStatus" -eq 0 ]; then
            vvtermZellijClientCount="$(awk '
              NR == 1 {
                if (NF != 3 || $1 != "CLIENT_ID" || $2 != "ZELLIJ_PANE_ID" || $3 != "RUNNING_COMMAND") exit 2
                next
              }
              NF {
                count += 1
                if (count > \(ZellijRemoteSessionParser.maximumAttachedClientCount)) exit 2
              }
              END {
                if (NR == 0) exit 2
                print count + 0
              }
            ' "$vvtermZellijProbeFile")"
            vvtermZellijClientStatus=$?
            if [ "$vvtermZellijClientStatus" -ne 0 ]; then
              vvtermZellijClientCount='?'
            fi
          else
            vvtermZellijClientCount='?'
          fi
          case "$vvtermZellijClientCount" in
            '?'|[0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) ;;
            *) vvtermZellijClientCount='?' ;;
          esac
          printf 'name=%s\townership=%s\tclients=%s\n' \
            "$vvtermZellijSession" '\(ownership)' "$vvtermZellijClientCount"
        done <"$vvtermZellijListFile"
        """
        return try wrappedBoundedLaunchScript(script)
    }

    static func listPanesCommand(
        attachment: RemoteSessionAttachment,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        let identifier = attachment.identifier
        try requireValid(identifier)
        let namespace = ZellijSocketNamespace(ownership: attachment.ownership)
        let command = try render(
            arguments: [
                "--session",
                identifier.rawValue,
                "action",
                "list-panes",
                "--all",
                "--json"
            ],
            runtime: runtime
        )
        let ownershipGuard = attachment.ownership == .managed
            ? managedOwnershipGuardScript(identifier: identifier)
            : ""
        let script = """
        \(namespace.setupScript)
        \(attachment.ownership == .managed ? managedMetadataSetupScript() : "")
        \(ownershipGuard)
        \(command)
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func launchCommand(
        request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        let attachment = request.intent.attachment
        let identifier = attachment.identifier
        try requireValid(identifier)
        let namespace = ZellijSocketNamespace(ownership: attachment.ownership)
        let executable = try render(arguments: [], runtime: runtime)
        let attach = try render(
            arguments: ["attach", identifier.rawValue],
            runtime: runtime
        )
        let attached = quotedMarker(request.lifecycleEnvelope, .attached)
        let detached = quotedMarker(request.lifecycleEnvelope, .detached)
        let terminated = quotedMarker(request.lifecycleEnvelope, .terminated)
        let creationFailed = quotedMarker(request.lifecycleEnvelope, .creationFailed)
        let attachFailed = quotedMarker(request.lifecycleEnvelope, .attachFailed)
        let failureMarker: String
        let intentScript: String

        switch request.intent {
        case .attach(let existingAttachment):
            failureMarker = attachFailed
            let ownershipGuard = existingAttachment.ownership == .managed
                ? """
                  if [ ! -f "$vvtermZellijOwnershipMarker" ] \
                     || [ -L "$vvtermZellijOwnershipMarker" ]; then
                    printf '%s' \(attachFailed)
                    exit 0
                  fi
                """
                : ""
            intentScript = """
            \(ownershipGuard)
            vvtermZellijProbe
            if [ "$vvtermZellijState" != live ]; then
              printf '%s' \(attachFailed)
              exit 0
            fi
            """
        case .ensureManaged(_, let initialCommand):
            failureMarker = creationFailed
            guard attachment.ownership == .managed else {
                throw SSHError.unknown("VVTerm can create only managed Zellij sessions")
            }
            let command = try validatedStartupCommand(initialCommand)
            let create = try managedCreateCommand(
                identifier: identifier,
                initialCommand: command,
                workingDirectory: request.workingDirectory,
                runtime: runtime
            )
            intentScript = """
            if ! vvtermZellijAcquireCreationLock; then
              printf '%s' \(creationFailed)
              exit 0
            fi
            vvtermZellijProbe
            case "$vvtermZellijState" in
              live)
                if [ ! -f "$vvtermZellijOwnershipMarker" ] \
                   || [ -L "$vvtermZellijOwnershipMarker" ]; then
                  vvtermZellijReleaseCreationLock
                  printf '%s' \(creationFailed)
                  exit 0
                fi
                ;;
              missing)
                if [ -e "$vvtermZellijOwnershipMarker" ] \
                   && { [ ! -f "$vvtermZellijOwnershipMarker" ] \
                        || [ -L "$vvtermZellijOwnershipMarker" ]; }; then
                  vvtermZellijReleaseCreationLock
                  printf '%s' \(creationFailed)
                  exit 0
                fi
                if [ ! -f "$vvtermZellijOwnershipMarker" ]; then
                  (umask 077; printf '%s\n' 'managed-v1' \
                    >"$vvtermZellijOwnershipMarker") 2>/dev/null \
                    && chmod 600 "$vvtermZellijOwnershipMarker" || {
                      vvtermZellijReleaseCreationLock
                      printf '%s' \(creationFailed)
                      exit 0
                    }
                fi
                \(create) >/dev/null 2>&1
                vvtermZellijCreateStatus=$?
                vvtermZellijProbe
                if [ "$vvtermZellijCreateStatus" -ne 0 ] \
                   || [ "$vvtermZellijState" != live ]; then
                  vvtermZellijReleaseCreationLock
                  printf '%s' \(creationFailed)
                  exit 0
                fi
                ;;
              *)
                vvtermZellijReleaseCreationLock
                printf '%s' \(creationFailed)
                exit 0
                ;;
            esac
            vvtermZellijReleaseCreationLock
            """
        }

        let managedSetup = attachment.ownership == .managed
            ? """
              \(managedMetadataSetupScript())
              vvtermZellijOwnershipMarker="$vvtermZellijOwnershipRoot/$vvtermZellijSessionName"
              vvtermZellijCreationLock="$vvtermZellijLockRoot/$vvtermZellijSessionName.lock"
              \(creationLockFunctions())
            """
            : "vvtermZellijReleaseCreationLock() { :; }"
        let terminalEnvironment = RemoteTerminalBootstrap.environmentExportScript(
            transport: request.transport
        )
        let script = """
        \(RemoteTerminalBootstrap.shellPathExport())
        \(terminalEnvironment)
        \(namespace.setupScript)
        vvtermZellijSessionName=\(RemoteTerminalBootstrap.shellQuoted(identifier.rawValue))
        \(managedSetup)
        vvtermZellijOwnsCreationLock=0
        umask 077
        vvtermZellijProbeFile="$(mktemp "${TMPDIR:-/tmp}/vvterm-zellij-probe.XXXXXX")" || {
          printf '%s' \(failureMarker)
          exit 0
        }
        vvtermZellijProbeStatusFile="$(mktemp "${TMPDIR:-/tmp}/vvterm-zellij-status.XXXXXX")" || {
          rm -f "$vvtermZellijProbeFile"
          printf '%s' \(failureMarker)
          exit 0
        }
        chmod 600 "$vvtermZellijProbeFile" "$vvtermZellijProbeStatusFile" || {
          rm -f "$vvtermZellijProbeFile" "$vvtermZellijProbeStatusFile"
          printf '%s' \(failureMarker)
          exit 0
        }
        vvtermZellijCleanup() {
          vvtermZellijReleaseCreationLock
          rm -f "$vvtermZellijProbeFile" "$vvtermZellijProbeStatusFile"
        }
        trap 'vvtermZellijCleanup; exit 0' HUP INT TERM
        trap vvtermZellijCleanup EXIT
        \(liveProbeFunction(executable: executable))
        \(intentScript)
        printf '%s' \(attached)
        \(attach)
        vvtermZellijAttachStatus=$?
        if [ "$vvtermZellijAttachStatus" -ne 0 ]; then
          printf '%s' \(attachFailed)
        else
          vvtermZellijProbe
          case "$vvtermZellijState" in
            live) printf '%s' \(detached) ;;
            missing) printf '%s' \(terminated) ;;
          esac
        fi
        """
        return try wrappedBoundedLaunchScript(script)
    }

    static func presenceProbe(
        attachment: RemoteSessionAttachment,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionPresenceProbe {
        let identifier = attachment.identifier
        try requireValid(identifier)
        let markerID = UUID().uuidString
        let existsMarker = "__VVTERM_SESSION_EXISTS_\(markerID)__"
        let missingMarker = "__VVTERM_SESSION_MISSING_\(markerID)__"
        let namespace = ZellijSocketNamespace(ownership: attachment.ownership)
        let executable = try render(arguments: [], runtime: runtime)
        let managedSetup = attachment.ownership == .managed
            ? """
              \(managedMetadataSetupScript())
              vvtermZellijOwnershipMarker="$vvtermZellijOwnershipRoot/$vvtermZellijSessionName"
            """
            : ""
        let ownershipCondition = attachment.ownership == .managed
            ? "[ -f \"$vvtermZellijOwnershipMarker\" ] && [ ! -L \"$vvtermZellijOwnershipMarker\" ]"
            : "true"
        let script = """
        \(namespace.setupScript)
        vvtermZellijSessionName=\(RemoteTerminalBootstrap.shellQuoted(identifier.rawValue))
        \(managedSetup)
        umask 077
        vvtermZellijProbeFile="$(mktemp "${TMPDIR:-/tmp}/vvterm-zellij-probe.XXXXXX")" || exit 0
        vvtermZellijProbeStatusFile="$(mktemp "${TMPDIR:-/tmp}/vvterm-zellij-status.XXXXXX")" || {
          rm -f "$vvtermZellijProbeFile"
          exit 0
        }
        chmod 600 "$vvtermZellijProbeFile" "$vvtermZellijProbeStatusFile" || {
          rm -f "$vvtermZellijProbeFile" "$vvtermZellijProbeStatusFile"
          exit 0
        }
        vvtermZellijCleanupProbeFiles() {
          rm -f "$vvtermZellijProbeFile" "$vvtermZellijProbeStatusFile"
        }
        trap 'vvtermZellijCleanupProbeFiles; exit 0' HUP INT TERM
        trap vvtermZellijCleanupProbeFiles EXIT
        \(liveProbeFunction(executable: executable))
        if [ "$vvtermZellijState" = live ]; then
          if \(ownershipCondition); then
            printf '%s' \(RemoteTerminalBootstrap.shellQuoted(existsMarker))
          else
            printf '%s' \(RemoteTerminalBootstrap.shellQuoted(missingMarker))
          fi
        elif [ "$vvtermZellijState" = missing ]; then
          printf '%s' \(RemoteTerminalBootstrap.shellQuoted(missingMarker))
        fi
        """
        return RemoteSessionPresenceProbe(
            command: RemoteTerminalBootstrap.wrapPOSIXShellCommand(script),
            existsMarker: existsMarker,
            missingMarker: missingMarker
        )
    }

    static func killManagedCommand(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        try requireValid(identifier)
        let kill = try render(
            arguments: ["kill-session", identifier.rawValue],
            runtime: runtime
        )
        let script = """
        \(ZellijSocketNamespace.managed.setupScript)
        \(managedMetadataSetupScript())
        vvtermZellijSessionName=\(RemoteTerminalBootstrap.shellQuoted(identifier.rawValue))
        vvtermZellijOwnershipMarker="$vvtermZellijOwnershipRoot/$vvtermZellijSessionName"
        [ -f "$vvtermZellijOwnershipMarker" ] \
          && [ ! -L "$vvtermZellijOwnershipMarker" ] || exit 1
        \(kill) >/dev/null 2>&1 || exit $?
        rm -f "$vvtermZellijOwnershipMarker"
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    private static func managedCreateCommand(
        identifier: RemoteSessionIdentifier,
        initialCommand: String?,
        workingDirectory: String,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        var arguments: [String] = []
        if let initialCommand {
            let encodedCommand = try ZellijKDLStringEncoder.encode(initialCommand)
            let layout = "layout { pane command=\"/bin/sh\" { "
                + "args \"-lc\" \(encodedCommand); }; }"
            guard layout.utf8.count <= ZellijKDLStringEncoder.maximumEncodedByteCount else {
                throw SSHError.outputLimitExceeded
            }
            arguments.append(contentsOf: ["--layout-string", layout])
        }
        arguments.append(contentsOf: [
            "attach",
            "--create-background",
            identifier.rawValue,
            "options",
            "--session-serialization",
            "false"
        ])
        return try render(
            arguments: arguments,
            workingDirectory: workingDirectory == "~" ? nil : workingDirectory,
            runtime: runtime
        )
    }

    private static func validatedStartupCommand(_ command: String?) throws -> String? {
        guard let command,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        do {
            return try RemoteShellStartupAction(command: command).command
        } catch {
            throw SSHError.unknown("Invalid custom startup command")
        }
    }

    private static func managedMetadataSetupScript() -> String {
        """
        vvtermZellijMetadataRoot="$ZELLIJ_SOCKET_DIR/.vvterm"
        vvtermZellijOwnershipRoot="$vvtermZellijMetadataRoot/owned"
        vvtermZellijLockRoot="$vvtermZellijMetadataRoot/locks"
        for vvtermZellijDirectory in "$vvtermZellijMetadataRoot" \
                                      "$vvtermZellijOwnershipRoot" \
                                      "$vvtermZellijLockRoot"; do
          if [ ! -d "$vvtermZellijDirectory" ]; then
            (umask 077; mkdir "$vvtermZellijDirectory") 2>/dev/null || true
          fi
          [ -d "$vvtermZellijDirectory" ] \
            && [ ! -L "$vvtermZellijDirectory" ] \
            && chmod 700 "$vvtermZellijDirectory" || exit 1
        done
        """
    }

    private static func managedOwnershipGuardScript(
        identifier: RemoteSessionIdentifier
    ) -> String {
        """
        vvtermZellijSessionName=\(RemoteTerminalBootstrap.shellQuoted(identifier.rawValue))
        vvtermZellijOwnershipMarker="$vvtermZellijOwnershipRoot/$vvtermZellijSessionName"
        [ -f "$vvtermZellijOwnershipMarker" ] \
          && [ ! -L "$vvtermZellijOwnershipMarker" ] || exit 1
        """
    }

    private static func creationLockFunctions() -> String {
        """
        vvtermZellijReleaseCreationLock() {
          if [ "${vvtermZellijOwnsCreationLock:-0}" -eq 1 ]; then
            rmdir "$vvtermZellijCreationLock" 2>/dev/null || true
            vvtermZellijOwnsCreationLock=0
          fi
        }
        vvtermZellijAcquireCreationLock() {
          vvtermZellijLockAttempt=0
          while ! (umask 077; mkdir "$vvtermZellijCreationLock") 2>/dev/null; do
            vvtermZellijLockAttempt=$((vvtermZellijLockAttempt + 1))
            [ "$vvtermZellijLockAttempt" -lt 100 ] || return 1
            sleep 0.05
          done
          vvtermZellijOwnsCreationLock=1
        }
        """
    }

    private static func liveProbeFunction(executable: String) -> String {
        """
        vvtermZellijProbe() {
          : >"$vvtermZellijProbeFile" \
            && : >"$vvtermZellijProbeStatusFile" || {
            vvtermZellijState=unknown
            return
          }
          (\(executable) '--session' "$vvtermZellijSessionName" \
            'action' 'list-panes' '--json'; \
            printf '%s\n' "$?" >"$vvtermZellijProbeStatusFile") 2>&1 \
              | head -c \(ZellijRemoteSessionParser.maximumOutputBytes + 1) \
                >"$vvtermZellijProbeFile"
          vvtermZellijCaptureStatus=$?
          vvtermZellijProbeBytes="$(wc -c <"$vvtermZellijProbeFile" | tr -d '[:space:]')"
          vvtermZellijProbeStatus="$(sed -n '1p' "$vvtermZellijProbeStatusFile")"
          case "$vvtermZellijProbeBytes" in
            ''|*[!0-9]*) vvtermZellijState=unknown; return ;;
          esac
          case "$vvtermZellijProbeStatus" in
            ''|*[!0-9]*) vvtermZellijState=unknown; return ;;
          esac
          if [ "$vvtermZellijCaptureStatus" -ne 0 ] \
             || [ "$vvtermZellijProbeBytes" -gt \(ZellijRemoteSessionParser.maximumOutputBytes) ] \
             || [ "$vvtermZellijProbeStatus" -gt 255 ]; then
            vvtermZellijState=unknown
          elif [ "$vvtermZellijProbeStatus" -eq 0 ]; then
            vvtermZellijState=live
          else
            vvtermZellijProbeFirstLine="$(sed -n '1p' "$vvtermZellijProbeFile")"
            vvtermZellijExpectedMissing="Session '$vvtermZellijSessionName' not found. The following sessions are active:"
            if [ "$vvtermZellijProbeFirstLine" = 'There is no active session!' ] \
               || [ "$vvtermZellijProbeFirstLine" = "$vvtermZellijExpectedMissing" ]; then
              vvtermZellijState=missing
            else
              vvtermZellijState=unknown
            fi
          fi
        }
        """
    }

    private static func render(
        arguments: [String],
        workingDirectory: String? = nil,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        guard runtime.probe.backendIdentifier == .zellij,
              runtime.probe.shellFamily == .posix else {
            throw SSHError.unknown("Zellij requires a POSIX remote shell")
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
        guard identifier.backendIdentifier == .zellij,
              ZellijRemoteSessionParser.isValidSessionName(identifier.rawValue) else {
            throw SSHError.unknown("Invalid Zellij session identifier")
        }
    }

    private static func wrappedBoundedLaunchScript(_ script: String) throws -> String {
        let command = RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
        guard command.utf8.count <= maximumLaunchCommandBytes else {
            throw SSHError.outputLimitExceeded
        }
        return command
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
