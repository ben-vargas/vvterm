import Foundation

nonisolated extension RemoteTmuxCommandBuilder {
    private static func managedWindowsConfigurationCommand(
        sessionName: String,
        backend: RemoteTmuxBackend,
        themeStyle: RemoteSessionThemeStyle
    ) -> String {
        let tmux = tmuxCommand(includeUTF8: false, backend: backend)
        let sessionTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let settings = [
            (name: "allow-passthrough", value: "on"),
            (name: "allow-set-title", value: "on"),
            (name: "mode-style", value: themeStyle.modeStyle),
            // `clear` sends E3 followed by 2J. Keep this override on each
            // managed window so the visible grid is not restored into history.
            (name: "scroll-on-clear", value: "off")
        ]
        let existingWindowCommands = settings.map { setting in
            let value = RemoteTerminalBootstrap.shellQuoted(setting.value)
            return "\(tmux) set-option -wq -t \"$vvtermWindow\" \(setting.name) \(value)"
        }.joined(separator: " && ")
        let futureWindowCommands = settings.map { setting in
            let value = RemoteTerminalBootstrap.shellQuoted(setting.value)
            return "set-option -wq \(setting.name) \(value)"
        }.joined(separator: " ; ")
        // Window options belong to the window object, so skip linked windows
        // that may also be visible in a user's external session.
        let windowListingFormat = RemoteTerminalBootstrap.shellQuoted(
            "#{window_id} #{window_linked}"
        )
        let unlinkedWindowCondition = RemoteTerminalBootstrap.shellQuoted(
            "#{==:#{window_linked},0}"
        )
        let guardedFutureWindowCommands = [
            "if-shell -F",
            unlinkedWindowCondition,
            RemoteTerminalBootstrap.shellQuoted(futureWindowCommands)
        ].joined(separator: " ")
        // A stable array index makes reattach idempotent without replacing
        // other session-local after-new-window hooks.
        let hookName = RemoteTerminalBootstrap.shellQuoted("after-new-window[1000]")
        let hookCommand = RemoteTerminalBootstrap.shellQuoted(guardedFutureWindowCommands)

        return """
        (vvtermWindows="$(\(tmux) list-windows -t \(sessionTarget) -F \(windowListingFormat) 2>/dev/null)" || exit 1; \
        printf '%s\\n' "$vvtermWindows" | while IFS=' ' read -r vvtermWindow vvtermLinked; do \
        [ "$vvtermLinked" = 0 ] || continue; \(existingWindowCommands) || exit 1; done || exit 1; \
        \(tmux) set-hook -t \(sessionTarget) \(hookName) \(hookCommand) 2>/dev/null || true)
        """
    }

    private static func shellDirectoryArgument(_ value: String) -> String {
        if value == "~" {
            return "\"${HOME}\""
        }
        return RemoteTerminalBootstrap.shellQuoted(value)
    }

    static func attachExistingBody(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil,
        themeStyle: RemoteSessionThemeStyle,
        reportsCreationFailure: Bool = false,
        requiresManagedMarker: Bool = false,
        ownership: RemoteSessionOwnership,
        transport: ShellTransport = .ssh
    ) -> String {
        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let plainSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let exactSessionOptionTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let plainSessionOptionTarget = RemoteTerminalBootstrap.shellQuoted("\(sessionName):")
        let tmuxProbe = tmuxCommand(includeUTF8: false, backend: backend)
        let usesManagedConfiguration = ownership == .managed
        let replacesProcess = lifecycleEnvelope == nil
        let managedConfiguration = usesManagedConfiguration
            ? "\(managedSessionConfigurationCommand(sessionName: sessionName, backend: backend, transport: transport)); \(managedWindowsConfigurationCommand(sessionName: sessionName, backend: backend, themeStyle: themeStyle)); "
            : ""
        let exactAttach = tmuxAttachCommand(
            target: exactSession,
            backend: backend,
            replacesProcess: replacesProcess,
            advertisesManagedFeatures: usesManagedConfiguration
        )
        let plainAttach = tmuxAttachCommand(
            target: plainSession,
            backend: backend,
            replacesProcess: replacesProcess,
            advertisesManagedFeatures: usesManagedConfiguration
        )
        let creationStatusCapture = reportsCreationFailure && lifecycleEnvelope != nil
            ? "; vvtermTmuxCreateStatus=$?"
            : ""
        let exactManagedCheck = requiresManagedMarker
            ? " && \(tmuxProbe) show-options -v -q -t \(exactSessionOptionTarget) @vvterm-managed 2>/dev/null | grep -Fqx '1'"
            : ""
        let plainManagedCheck = requiresManagedMarker
            ? " && \(tmuxProbe) show-options -v -q -t \(plainSessionOptionTarget) @vvterm-managed 2>/dev/null | grep -Fqx '1'"
            : ""
        let collision = "false\(creationStatusCapture)"
        let attachedReport = posixAttachedReport(lifecycleEnvelope)

        let lifecycleReport: String
        if let lifecycleEnvelope {
            let detached = RemoteTerminalBootstrap.shellQuoted(
                RemoteSessionLifecycleMarker.sequence(envelope: lifecycleEnvelope, event: .detached)
            )
            let ended = RemoteTerminalBootstrap.shellQuoted(
                RemoteSessionLifecycleMarker.sequence(envelope: lifecycleEnvelope, event: .terminated)
            )
            if reportsCreationFailure {
                let creationFailed = RemoteTerminalBootstrap.shellQuoted(
                    RemoteSessionLifecycleMarker.sequence(envelope: lifecycleEnvelope, event: .creationFailed)
                )
                lifecycleReport = """
                ; if [ "${vvtermTmuxCreateStatus:-0}" -ne 0 ]; then printf '%s' \(creationFailed); \
                elif \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
                printf '%s' \(detached); else printf '%s' \(ended); fi
                """
            } else {
                lifecycleReport = """
                ; if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
                printf '%s' \(detached); else printf '%s' \(ended); fi
                """
            }
        } else {
            lifecycleReport = ""
        }

        return """
        \(RemoteTerminalBootstrap.shellPathExport()); \
        if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null\(exactManagedCheck); then \
        \(managedConfiguration)\(attachedReport)\(exactAttach); \
        elif \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null\(plainManagedCheck); then \
        \(managedConfiguration)\(attachedReport)\(plainAttach); \
        elif \(requiresManagedMarker ? "\(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null" : "false"); then \
        \(collision); \
        else \(missingCommand)\(creationStatusCapture); fi\(lifecycleReport)
        """
    }

    static func createSessionCommand(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String?,
        backend: RemoteTmuxBackend = .unixTmux,
        themeStyle: RemoteSessionThemeStyle,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        let escapedDir = shellDirectoryArgument(workingDirectory)
        let escapedSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let sessionWindowTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let bootstrapWindowName = "__vvterm_bootstrap__"
        let escapedBootstrapWindow = RemoteTerminalBootstrap.shellQuoted(bootstrapWindowName)
        let bootstrapWindowTarget = RemoteTerminalBootstrap.shellQuoted(
            "=\(sessionName):\(bootstrapWindowName)"
        )
        let tmux = tmuxCommand(includeUTF8: false, backend: backend)
        let sessionConfiguration = managedSessionConfigurationCommand(
            sessionName: sessionName,
            backend: backend,
            transport: transport
        )
        let windowsConfiguration = managedWindowsConfigurationCommand(
            sessionName: sessionName,
            backend: backend,
            themeStyle: themeStyle
        )
        let createBootstrap = "\(tmux) new-session -d -s \(escapedSession) -n \(escapedBootstrapWindow) -c \(escapedDir) \(RemoteTerminalBootstrap.shellQuoted("sleep 86400"))"
        let terminalCommand = RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            initialCommand ?? RemoteTerminalBootstrap.defaultLoginShellCommand()
        )
        let createTerminalWindow = "\(tmux) new-window -d -t \(sessionWindowTarget) -c \(escapedDir) \(terminalCommand)"
        let removeBootstrap = "\(tmux) kill-window -t \(bootstrapWindowTarget)"
        let renumberWindows = "\(tmux) move-window -r -t \(sessionWindowTarget)"
        let removeFailedSession = "\(tmux) kill-session -t \(exactSession) 2>/dev/null"
        let attachCommand = tmuxAttachCommand(
            target: escapedSession,
            backend: backend,
            replacesProcess: lifecycleEnvelope == nil,
            advertisesManagedFeatures: true
        )
        let attach = "\(posixAttachedReport(lifecycleEnvelope))\(attachCommand)"
        return """
        if \(createBootstrap) 2>/dev/null; then \
        if \(sessionConfiguration) && \
        \(createTerminalWindow) 2>/dev/null && \
        \(removeBootstrap) 2>/dev/null && \
        \(renumberWindows) 2>/dev/null && \
        \(windowsConfiguration); then \(attach); \
        else \(removeFailedSession); false; fi; \
        elif \(tmux) has-session -t \(exactSession) 2>/dev/null && \
        \(tmux) show-options -v -q -t \(sessionWindowTarget) @vvterm-managed 2>/dev/null | grep -Fqx '1'; then \
        \(sessionConfiguration); \(windowsConfiguration); \(attach); \
        else false; fi
        """
    }

    private static func managedSessionConfigurationCommand(
        sessionName: String,
        backend: RemoteTmuxBackend,
        transport: ShellTransport
    ) -> String {
        let tmux = tmuxCommand(includeUTF8: false, backend: backend)
        let sessionOptionTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let sessionEnvironmentTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let paneTitle = RemoteTerminalBootstrap.shellQuoted("#{pane_title}")
        let windowLinked = RemoteTerminalBootstrap.shellQuoted("#{window_linked}")
        // tmux can apply history-limit through the selected linked window.
        // Skip it when that could change an external session.
        let historyLimit = """
        if \(tmux) list-windows -t \(sessionOptionTarget) -F \(windowLinked) 2>/dev/null | grep -Fqx '1'; then :; \
        else \(tmux) set-option -q -t \(sessionOptionTarget) history-limit 10000; fi
        """

        var commands = [
            "\(tmux) set-option -q -t \(sessionOptionTarget) @vvterm-managed 1",
            "\(tmux) set-option -q -t \(sessionOptionTarget) status off",
            historyLimit,
            "\(tmux) set-option -q -t \(sessionOptionTarget) mouse on",
            "\(tmux) set-option -q -t \(sessionOptionTarget) set-titles on",
            "\(tmux) set-option -q -t \(sessionOptionTarget) set-titles-string \(paneTitle)"
        ]
        let terminalEnvironment = RemoteTerminalBootstrap.terminalEnvironment(transport: transport)
        commands.append(contentsOf: terminalEnvironment.map { variable in
            let value = RemoteTerminalBootstrap.shellQuoted(variable.value)
            return "\(tmux) set-environment -t \(sessionEnvironmentTarget) \(variable.name) \(value)"
        })
        if !terminalEnvironment.contains(where: {
            $0.name == RemoteKittyGraphicsPolicy.compatibilityEnvironmentName
        }) {
            commands.append(
                "\(tmux) set-environment -u -t \(sessionEnvironmentTarget) \(RemoteKittyGraphicsPolicy.compatibilityEnvironmentName)"
            )
        }
        if !RemoteKittyGraphicsPolicy(transport: transport).supportsKittyGraphics {
            commands.append(contentsOf: RemoteTerminalBootstrap.terminalProgramEnvironment().map { variable in
                "\(tmux) set-environment -u -t \(sessionEnvironmentTarget) \(variable.name)"
            })
        }
        return commands.joined(separator: " && ")
    }

    private static func tmuxAttachCommand(
        target: String,
        backend: RemoteTmuxBackend,
        replacesProcess: Bool,
        advertisesManagedFeatures: Bool
    ) -> String {
        let processReplacement = replacesProcess ? "exec " : ""
        let tmux = tmuxCommand(includeUTF8: true, backend: backend)
        let attach = "\(processReplacement)\(tmux) attach-session -t \(target)"
        guard advertisesManagedFeatures else { return attach }

        let features = "-T RGB,hyperlinks"
        return "if \(tmux) \(features) -V >/dev/null 2>&1; then \(processReplacement)\(tmux) \(features) attach-session -t \(target); else \(attach); fi"
    }

    private static func posixAttachedReport(
        _ lifecycleEnvelope: RemoteSessionLifecycleEnvelope?
    ) -> String {
        guard let marker = attachedMarker(lifecycleEnvelope) else { return "" }
        let attached = RemoteTerminalBootstrap.shellQuoted(marker)
        return "printf '%s' \(attached); "
    }

    static func tmuxCommand(
        includeUTF8: Bool,
        backend: RemoteTmuxBackend
    ) -> String {
        var parts = [RemoteTerminalBootstrap.shellQuoted(backend.executablePath)]
        if includeUTF8 {
            parts.append("-u")
        }
        return parts.joined(separator: " ")
    }

    static func tmuxAvailabilityProbeCommand(okMarker: String) -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        VVTERM_TMUX_BIN="";
        if command -v tmux >/dev/null 2>&1; then
          VVTERM_TMUX_BIN="$(command -v tmux 2>/dev/null)";
        fi;
        if [ -z "$VVTERM_TMUX_BIN" ]; then
          for candidate in /usr/bin/tmux /bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /snap/bin/tmux; do
            if [ -x "$candidate" ]; then
              VVTERM_TMUX_BIN="$candidate";
              break;
            fi;
          done;
        fi;
        if [ -n "$VVTERM_TMUX_BIN" ] && "$VVTERM_TMUX_BIN" -V >/dev/null 2>&1; then
          VVTERM_TMUX_VERSION="$("$VVTERM_TMUX_BIN" -V 2>/dev/null | head -n 1)";
          printf '%s\n__VVTERM_TMUX_PATH__%s\n__VVTERM_TMUX_VERSION__%s\n' '\(okMarker)' "$VVTERM_TMUX_BIN" "$VVTERM_TMUX_VERSION";
        else
          printf '__VVTERM_TMUX_NO__';
        fi
        """
        return "sh -c \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

}
