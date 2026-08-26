import Foundation

nonisolated enum RemoteTmuxCommandBuilder {
    static func attachCommand(
        themeStyle: RemoteSessionThemeStyle,
        sessionName: String,
        workingDirectory: String,
        initialCommand: String? = nil,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        let body = ensureManagedBody(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            themeStyle: themeStyle,
            backend: backend,
            lifecycleEnvelope: lifecycleEnvelope,
            transport: transport
        )
        return body
    }

    static func attachExistingCommand(
        themeStyle: RemoteSessionThemeStyle,
        sessionName: String,
        ownership: RemoteSessionOwnership,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        let body = attachExistingBody(
            sessionName: sessionName,
            missingCommand: lifecycleEnvelope == nil
                ? missingSessionCommand(backend: backend)
                : lifecycleMissingSessionCommand(backend: backend),
            backend: backend,
            lifecycleEnvelope: lifecycleEnvelope,
            themeStyle: themeStyle,
            ownership: ownership,
            transport: transport
        )
        return body
    }

    static func sessionPresenceProbeCommand(
        sessionName: String,
        backend: RemoteTmuxBackend = .unixTmux,
        existsMarker: String,
        missingMarker: String
    ) -> String {
        if backend.isWindows {
            let commandName = backend.commandName
            let script = """
            $vvtermPsmux = \(powerShellQuoted(commandName))
            $vvtermSession = \(powerShellQuoted(sessionName))
            & $vvtermPsmux has-session -t $vvtermSession 2>$null
            if ($LASTEXITCODE -eq 0) {
              [Console]::Out.Write(\(powerShellQuoted(existsMarker)))
            } else {
              [Console]::Out.Write(\(powerShellQuoted(missingMarker)))
            }
            """
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }

        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let plainSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let exists = RemoteTerminalBootstrap.shellQuoted(existsMarker)
        let missing = RemoteTerminalBootstrap.shellQuoted(missingMarker)
        let tmuxProbe = tmuxCommand(includeUTF8: false, backend: backend)
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport()); \
        if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
        printf '%s' \(exists); else printf '%s' \(missing); fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    static func installAndAttachScript(
        themeStyle: RemoteSessionThemeStyle,
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend = .unixTmux,
        attachAfterInstall: Bool = true
    ) -> String {
        if backend.isWindows {
            return windowsInstallAndAttachScript(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                terminalType: terminalType,
                themeStyle: themeStyle,
                backend: backend,
                attachAfterInstall: attachAfterInstall
            )
        }

        let attach = attachCommand(
            themeStyle: themeStyle,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend
        )
        let afterInstall = attachAfterInstall ? attach : ":"

        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v tmux >/dev/null 2>&1; then
          \(afterInstall);
        else
          if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi;
          OS_NAME="$(uname -s)";
          if [ "$OS_NAME" = "Darwin" ]; then
            if command -v brew >/dev/null 2>&1; then
              brew install tmux;
            elif command -v port >/dev/null 2>&1; then
              $SUDO port install tmux;
            else
              echo "No supported package manager found for macOS.";
            fi;
          elif [ "$OS_NAME" = "Linux" ]; then
            if command -v apt-get >/dev/null 2>&1; then
              $SUDO apt-get update && $SUDO apt-get install -y tmux;
            elif command -v dnf >/dev/null 2>&1; then
              $SUDO dnf install -y tmux;
            elif command -v yum >/dev/null 2>&1; then
              $SUDO yum install -y tmux;
            elif command -v pacman >/dev/null 2>&1; then
              $SUDO pacman -Sy --noconfirm tmux;
            elif command -v apk >/dev/null 2>&1; then
              $SUDO apk add tmux;
            elif command -v zypper >/dev/null 2>&1; then
              $SUDO zypper -n install tmux;
            elif command -v xbps-install >/dev/null 2>&1; then
              $SUDO xbps-install -Sy tmux;
            elif command -v opkg >/dev/null 2>&1; then
              $SUDO opkg update && $SUDO opkg install tmux;
            elif command -v emerge >/dev/null 2>&1; then
              $SUDO emerge app-misc/tmux;
            elif command -v pkg >/dev/null 2>&1; then
              $SUDO pkg install -y tmux;
            else
              echo "No supported package manager found for Linux.";
            fi;
          else
            echo "Unsupported OS: $OS_NAME";
          fi;
        fi;
        if command -v tmux >/dev/null 2>&1; then \(afterInstall); else echo "tmux installation failed."; fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    private static func shellDirectoryArgument(_ value: String) -> String {
        if value == "~" {
            return "\"${HOME}\""
        }
        return RemoteTerminalBootstrap.shellQuoted(value)
    }

    private static func missingSessionCommand(backend: RemoteTmuxBackend) -> String {
        if backend.isWindows {
            return windowsDefaultShellCommand(backend: backend)
        }
        return "exec \"${SHELL:-/bin/sh}\" -l"
    }

    private static func ensureManagedBody(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String?,
        themeStyle: RemoteSessionThemeStyle,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        if backend.isWindows {
            return windowsEnsureManagedCommand(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                backend: backend,
                themeStyle: themeStyle,
                lifecycleEnvelope: lifecycleEnvelope
            )
        }

        let createCommand = createSessionCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            backend: backend,
            themeStyle: themeStyle,
            lifecycleEnvelope: lifecycleEnvelope,
            transport: transport
        )
        return attachExistingBody(
            sessionName: sessionName,
            missingCommand: createCommand,
            backend: backend,
            lifecycleEnvelope: lifecycleEnvelope,
            themeStyle: themeStyle,
            reportsCreationFailure: true,
            requiresManagedMarker: true,
            ownership: .managed,
            transport: transport
        )
    }

    private static func attachExistingBody(
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
        if backend.isWindows {
            return windowsAttachExistingCommand(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend,
                lifecycleEnvelope: lifecycleEnvelope,
                themeStyle: themeStyle,
                reportsCreationFailure: reportsCreationFailure,
                requiresManagedMarker: requiresManagedMarker,
                ownership: ownership
            )
        }

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
        \(managedConfiguration)\(exactAttach); \
        elif \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null\(plainManagedCheck); then \
        \(managedConfiguration)\(plainAttach); \
        elif \(requiresManagedMarker ? "\(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null" : "false"); then \
        \(collision); \
        else \(missingCommand)\(creationStatusCapture); fi\(lifecycleReport)
        """
    }

    private static func createSessionCommand(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String?,
        backend: RemoteTmuxBackend = .unixTmux,
        themeStyle: RemoteSessionThemeStyle,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        if backend.isWindows {
            return windowsCreateSessionCommand(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                backend: backend
            )
        }

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
        let attach = tmuxAttachCommand(
            target: escapedSession,
            backend: backend,
            replacesProcess: lifecycleEnvelope == nil,
            advertisesManagedFeatures: true
        )
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

    private static func lifecycleMissingSessionCommand(backend: RemoteTmuxBackend) -> String {
        backend.isWindows ? "$null" : ":"
    }

    private static func tmuxCommand(
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

    static func windowsPowerShellExecutable(
        for environment: RemoteEnvironment
    ) -> String? {
        if let executable = environment.powerShellExecutable, !executable.isEmpty {
            return executable
        }
        guard environment.shellProfile.family == .powershell,
              let executable = environment.shellProfile.executableName,
              !executable.isEmpty else {
            return nil
        }
        return executable
    }

    static func windowsPsmuxAvailabilityProbeCommand(
        commandName: String,
        backend: RemoteTmuxBackend,
        requirePsmuxExtension: Bool
    ) -> String {
        let availableMarker = "__VVTERM_TMUX_OK__:\(commandName)"
        let missingMarker = "__VVTERM_TMUX_NO__:\(commandName)"
        let script = """
        $vvtermAvailable = $false
        $cmd = Get-Command \(powerShellQuoted(commandName)) -ErrorAction SilentlyContinue
        if ($cmd) {
          & $cmd.Source -V *> $null
          if ($LASTEXITCODE -eq 0) {
            $vvtermCommands = (& $cmd.Source list-commands 2>$null) -join "`n"
            if (-not \(requirePsmuxExtension ? "$true" : "$false") -or $vvtermCommands.Contains('dump-state') -or $vvtermCommands.Contains('claim-session')) {
              $vvtermAvailable = $true
            }
          }
        }
        if ($vvtermAvailable) {
          $vvtermVersion = (& $cmd.Source -V 2>$null | Select-Object -First 1)
          Write-Output \(powerShellQuoted(availableMarker))
          Write-Output (\(powerShellQuoted("__VVTERM_TMUX_PATH__")) + $cmd.Source)
          Write-Output (\(powerShellQuoted("__VVTERM_TMUX_VERSION__")) + $vvtermVersion)
        } else {
          Write-Output \(powerShellQuoted(missingMarker))
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    static func listSessionCommands(backend: RemoteTmuxBackend) -> [String] {
        switch backend.variant {
        case .unixTmux:
            let tmux = tmuxCommand(includeUTF8: false, backend: backend)
            let bodies = [
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name}\\t#{session_attached}\\t#{session_windows}\\t#{@vvterm-managed}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name} #{session_attached} #{session_windows}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions 2>/dev/null"
            ]
            return bodies.map { "sh -lc \(RemoteTerminalBootstrap.shellQuoted($0))" }

        case .windowsPsmux:
            let commandName = backend.commandName
            return [
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name}\\t#{session_attached}\\t#{session_windows}\\t#{@vvterm-managed}", backend: backend),
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name} #{session_attached} #{session_windows}", backend: backend),
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name} #{session_attached}", backend: backend),
                windowsShellCommand(
                    powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions 2>$null",
                    backend: backend
                )
            ]
        }
    }

    private static func windowsPsmuxListSessionsCommand(
        commandName: String,
        format: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions -F \(powerShellQuoted(format)) 2>$null",
            backend: backend
        )
    }

    static func killSessionCommand(named sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend.variant {
        case .unixTmux:
            let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false, backend: backend)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) kill-session -t \(quoted) 2>/dev/null || true"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux:
            let commandName = backend.commandName
            let script = "& \(powerShellQuoted(commandName)) kill-session -t \(powerShellQuoted(sessionName)) 2>$null"
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }
    }

    static func currentPathCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend.variant {
        case .unixTmux:
            let quotedSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false, backend: backend)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-panes -t \(quotedSession) -F '#{pane_current_path}' 2>/dev/null | head -n 1"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux:
            let commandName = backend.commandName
            let script = "& \(powerShellQuoted(commandName)) list-panes -t \(powerShellQuoted(sessionName)) -F '#{pane_current_path}' 2>$null | Select-Object -First 1"
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }
    }

    private static func windowsEnsureManagedCommand(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String?,
        backend: RemoteTmuxBackend,
        themeStyle: RemoteSessionThemeStyle,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope?
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsEnsureManagedPowerShell(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                backend: backend,
                themeStyle: themeStyle,
                lifecycleEnvelope: lifecycleEnvelope
            ),
            backend: backend
        )
    }

    private static func windowsAttachExistingCommand(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope?,
        themeStyle: RemoteSessionThemeStyle,
        reportsCreationFailure: Bool = false,
        requiresManagedMarker: Bool,
        ownership: RemoteSessionOwnership
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsAttachExistingPowerShell(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend,
                themeStyle: themeStyle,
                lifecycleEnvelope: lifecycleEnvelope,
                reportsCreationFailure: reportsCreationFailure,
                requiresManagedMarker: requiresManagedMarker,
                ownership: ownership
            ),
            backend: backend
        )
    }

    private static func windowsEnsureManagedPowerShell(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String? = nil,
        backend: RemoteTmuxBackend,
        themeStyle: RemoteSessionThemeStyle,
        commandExpression: String? = nil,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil
    ) -> String {
        let createCommand = windowsCreateSessionPowerShell(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            backend: backend,
            commandExpression: commandExpression
        )
        return windowsAttachExistingPowerShell(
            sessionName: sessionName,
            missingCommand: createCommand,
            backend: backend,
            themeStyle: themeStyle,
            commandExpression: commandExpression,
            lifecycleEnvelope: lifecycleEnvelope,
            reportsCreationFailure: true,
            requiresManagedMarker: true,
            ownership: .managed
        )
    }

    private static func windowsAttachExistingPowerShell(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        themeStyle: RemoteSessionThemeStyle,
        commandExpression: String? = nil,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil,
        reportsCreationFailure: Bool = false,
        requiresManagedMarker: Bool = false,
        ownership: RemoteSessionOwnership
    ) -> String {
        guard backend.isWindows else { return missingCommand }
        let commandName = backend.commandName
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        let usesManagedConfiguration = ownership == .managed
        let configDeclaration = usesManagedConfiguration
            ? "$vvtermConfig = \(windowsConfigPathPowerShellExpression())"
            : ""
        let attachCommand = usesManagedConfiguration
            ? """
              & $vvtermPsmux source-file -t $vvtermSession $vvtermConfig 2>$null
              & $vvtermPsmux -u attach-session -d -t $vvtermSession
              """
            : "& $vvtermPsmux -u attach-session -d -t $vvtermSession"
        let existingSessionAction: String
        if requiresManagedMarker {
            existingSessionAction = """
            $vvtermManagedMarker = (& $vvtermPsmux display-message -p -t $vvtermSession '#{@vvterm-managed}' 2>$null | Select-Object -First 1)
            if ($vvtermManagedMarker -eq '1') {
            \(indentPowerShell(attachCommand, spaces: 2))
            } else {
              $vvtermTmuxCreateStatus = 1
            }
            """
        } else {
            existingSessionAction = attachCommand
        }
        let lifecycleReport: String
        if let lifecycleEnvelope {
            let detached = powerShellQuoted(
                RemoteSessionLifecycleMarker.sequence(envelope: lifecycleEnvelope, event: .detached)
            )
            let ended = powerShellQuoted(
                RemoteSessionLifecycleMarker.sequence(envelope: lifecycleEnvelope, event: .terminated)
            )
            let sessionPresenceReport = """
            & $vvtermPsmux has-session -t $vvtermSession 2>$null
            if ($LASTEXITCODE -eq 0) {
              [Console]::Out.Write(\(detached))
            } else {
              [Console]::Out.Write(\(ended))
            }
            """
            if reportsCreationFailure {
                let creationFailed = powerShellQuoted(
                    RemoteSessionLifecycleMarker.sequence(envelope: lifecycleEnvelope, event: .creationFailed)
                )
                lifecycleReport = """
                if ($null -ne $vvtermTmuxCreateStatus -and $vvtermTmuxCreateStatus -ne 0) {
                  [Console]::Out.Write(\(creationFailed))
                } else {
                  \(sessionPresenceReport)
                }
                """
            } else {
                lifecycleReport = sessionPresenceReport
            }
        } else {
            lifecycleReport = ""
        }

        return """
        $vvtermPsmux = \(psmuxExpression)
        \(configDeclaration)
        $vvtermSession = \(powerShellQuoted(sessionName))
        & $vvtermPsmux has-session -t $vvtermSession 2>$null
        if ($LASTEXITCODE -eq 0) {
        \(indentPowerShell(existingSessionAction, spaces: 2))
        } else {
        \(indentPowerShell(missingCommand, spaces: 2))
        \(reportsCreationFailure && lifecycleEnvelope != nil ? "  $vvtermTmuxCreateStatus = $LASTEXITCODE" : "")
        }
        \(lifecycleReport)
        """
    }

    private static func windowsCreateSessionCommand(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String?,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsCreateSessionPowerShell(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                backend: backend
            ),
            backend: backend
        )
    }

    private static func windowsCreateSessionPowerShell(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String? = nil,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil
    ) -> String {
        guard backend.isWindows else { return "" }
        let commandName = backend.commandName
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        return """
        $vvtermPsmux = \(psmuxExpression)
        $vvtermConfig = \(windowsConfigPathPowerShellExpression())
        $vvtermSession = \(powerShellQuoted(sessionName))
        $vvtermWorkingDirectory = \(windowsWorkingDirectoryExpression(workingDirectory))
        & $vvtermPsmux -u -f $vvtermConfig new-session -s $vvtermSession -c $vvtermWorkingDirectory\(initialCommand.map { " " + powerShellQuoted($0) } ?? "")
        """
    }

    private static func windowsDefaultShellCommand(backend: RemoteTmuxBackend) -> String {
        guard let shellFamily = backend.shellFamily else { return "" }
        let powerShellExecutable = backend.powerShellExecutable
        switch shellFamily {
        case .powershell:
            let executable = powerShellExecutable ?? "powershell"
            return "& \(powerShellQuoted(executable))"
        case .cmd:
            return "cmd.exe"
        case .unknown, .posix:
            if let executable = powerShellExecutable {
                return "& \(powerShellQuoted(executable))"
            }
            return ""
        }
    }

    private static func windowsConfigLines(
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle
    ) -> [String] {
        // psmux runs one server per session. VVTerm loads this global-looking
        // config only into the explicitly targeted managed-session server.
        let theme = themeStyle
        var lines = [
            "# VVTerm tmux configuration",
            "# Auto-generated by VVTerm - changes will be overwritten",
            "",
            "set -g @vvterm-managed 1",
            "",
            "# Preserve true-color and terminal metadata when attaching",
        ]
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "update-environment",
            values: RemoteTerminalBootstrap.tmuxUpdateEnvironmentVariables()
        ))
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxEnvironmentCommands())
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "terminal-features",
            values: ["*:hyperlinks"]
        ))
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "terminal-overrides",
            values: ["\(terminalType.rawValue):RGB"]
        ))
        lines.append(contentsOf: [
            "",
            "# Allow OSC sequences to pass through (title updates, etc.)",
            "set -g allow-passthrough on",
            "",
            "# Publish the active pane title to the outer VVTerm terminal"
        ])
        lines.append(contentsOf: titlePropagationConfigLines())
        lines.append(contentsOf: [
            "",
            "# Hide status bar",
            "set -g status off",
            "",
            "# Increase scrollback buffer",
            "set -g history-limit 10000",
            "",
            "# Enable mouse support",
            "set -g mouse on",
            "",
            "# Set default terminal with true color support",
            "set -g default-terminal \"\(terminalType.rawValue)\"",
            "",
            "# Selection highlighting in copy-mode (from theme: \(theme.name))",
            "set -g mode-style \"\(theme.modeStyle)\""
        ])

        lines.append(contentsOf: [
            "",
            "# Use psmux's native scroll behavior on Windows"
        ])

        return lines
    }

    static func windowsConfigWriteCommand(
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsConfigWritePowerShell(
                terminalType: terminalType,
                themeStyle: themeStyle,
                backend: backend
            ),
            backend: backend
        )
    }

    private static func windowsConfigWritePowerShell(
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        backend: RemoteTmuxBackend
    ) -> String {
        let lines = windowsConfigLines(
            terminalType: terminalType,
            themeStyle: themeStyle
        )
        let content = lines.joined(separator: "\n") + "\n"
        let defaultShellExpression: String?
        switch backend.shellFamily {
        case .powershell:
            defaultShellExpression = "[System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName"
        case .cmd:
            defaultShellExpression = "$env:ComSpec"
        case .unknown, .posix, nil:
            defaultShellExpression = nil
        }
        // This config is sourced again on reconnect. `-o` keeps this a one-time
        // choice for the VVTerm-managed psmux server.
        let defaultShellConfiguration = defaultShellExpression.map { expression in
            """
            $vvtermDefaultShell = \(expression)
            $vvtermDefaultShell = $vvtermDefaultShell.Replace('\\', '/')
            $vvtermConfigContent += "`n# Match the shell used by the VVTerm SSH connection`n"
            $vvtermConfigContent += "set -o default-shell `"$vvtermDefaultShell`"`n"
            """
        } ?? ""
        return """
        $vvtermConfigDirectory = \(windowsConfigDirectoryPowerShellExpression())
        $vvtermConfigPath = \(windowsConfigPathPowerShellExpression())
        New-Item -ItemType Directory -Force -Path $vvtermConfigDirectory | Out-Null
        $vvtermConfigContent = @'
        \(content)'@
        \(defaultShellConfiguration)
        $vvtermConfigContent | Set-Content -Encoding UTF8 -NoNewline -Path $vvtermConfigPath
        """
    }

    private static func titlePropagationConfigLines() -> [String] {
        [
            "set -g allow-set-title on",
            "set -g set-titles on",
            "set -g set-titles-string \"#{pane_title}\""
        ]
    }

    private static func windowsInstallAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        backend: RemoteTmuxBackend,
        attachAfterInstall: Bool
    ) -> String {
        let configWrite = windowsConfigWritePowerShell(
            terminalType: terminalType,
            themeStyle: themeStyle,
            backend: backend
        )
        let attach = windowsEnsureManagedPowerShell(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            themeStyle: themeStyle,
            commandExpression: "$vvtermPsmuxCommand.Source"
        )
        let afterInstall = attachAfterInstall ? attach : "Write-Output 'psmux installation completed.'"
        let script = """
        \(configWrite)
        function Get-VVTermPsmuxCommand {
          $cmd = Get-Command psmux -ErrorAction SilentlyContinue
          if (-not $cmd) {
            $cmd = Get-Command pmux -ErrorAction SilentlyContinue
          }
          return $cmd
        }
        $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
        $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        if (-not $vvtermPsmuxInstalled -and (Get-Command winget -ErrorAction SilentlyContinue)) {
          winget install --id marlocarlo.psmux --accept-package-agreements --accept-source-agreements
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
          scoop bucket add psmux https://github.com/psmux/scoop-psmux
          scoop install psmux
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command choco -ErrorAction SilentlyContinue)) {
          choco install psmux -y
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command cargo -ErrorAction SilentlyContinue)) {
          cargo install psmux
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if ($vvtermPsmuxInstalled) {
        \(indentPowerShell(afterInstall, spaces: 2))
        } else {
          Write-Output 'psmux installation failed or no supported package manager was found.'
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    private static func windowsShellCommand(
        powerShellScript: String,
        backend: RemoteTmuxBackend
    ) -> String {
        guard let shellFamily = backend.shellFamily else {
            return powerShellScript
        }
        let powerShellExecutable = backend.powerShellExecutable

        switch shellFamily {
        case .powershell:
            return powerShellScript
        case .cmd, .unknown, .posix:
            guard let executable = powerShellExecutable, !executable.isEmpty else {
                return ""
            }
            return RemoteTerminalBootstrap.wrapPowerShellCommand(
                powerShellScript,
                executableName: executable
            )
        }
    }

    private static func windowsConfigPathPowerShellExpression() -> String {
        "$HOME + \(powerShellQuoted("\\.vvterm\\psmux.conf"))"
    }

    private static func windowsConfigDirectoryPowerShellExpression() -> String {
        "$HOME + \(powerShellQuoted("\\.vvterm"))"
    }

    private static func windowsWorkingDirectoryExpression(_ value: String) -> String {
        guard !value.isEmpty else { return "$HOME" }
        if value == "~" || value == "$HOME" || value == "%USERPROFILE%" {
            return "$HOME"
        }
        let encoded = Data(normalizedWindowsPath(value).utf8).base64EncodedString()
        return "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encoded)'))"
    }

    private static func normalizedWindowsPath(_ value: String) -> String {
        let normalizedSlashes = value.replacingOccurrences(of: "/", with: "\\")
        if value.count >= 2 {
            let prefix = value.prefix(2)
            let drive = prefix.prefix(1)
            if drive.range(of: #"^[A-Za-z]$"#, options: .regularExpression) != nil,
               prefix.dropFirst() == ":" {
                return normalizedSlashes
            }
        }

        if value.count >= 3,
           value.first == "/",
           let drive = value.dropFirst().first,
           drive.isLetter {
            let remainder = value.dropFirst(2)
            let normalizedRemainder = remainder.replacingOccurrences(of: "/", with: "\\")
            return "\(drive.uppercased()):\(normalizedRemainder)"
        }

        return value
    }

    private static func powerShellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func indentPowerShell(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : prefix + line
            }
            .joined(separator: "\n")
    }

}
