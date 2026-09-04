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
        let missingCommand = lifecycleEnvelope == nil
            ? missingSessionCommand(backend: backend)
            : lifecycleMissingSessionCommand(backend: backend)
        if backend.isWindows {
            return windowsAttachExistingCommand(
                sessionName: sessionName, missingCommand: missingCommand,
                backend: backend, lifecycleEnvelope: lifecycleEnvelope,
                themeStyle: themeStyle, reportsCreationFailure: false,
                requiresManagedMarker: false, ownership: ownership
            )
        }
        return attachExistingBody(
            sessionName: sessionName,
            missingCommand: missingCommand,
            backend: backend,
            lifecycleEnvelope: lifecycleEnvelope,
            themeStyle: themeStyle,
            ownership: ownership,
            transport: transport
        )
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
                    powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions 2>$null; \(windowsSessionListCompletion)",
                    backend: backend
                )
            ]
        }
    }

    static let sessionListSuccessMarker = "__VVTERM_TMUX_LIST_OK__"

    static func killSessionCommand(named sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend.variant {
        case .unixTmux:
            let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false, backend: backend)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) kill-session -t \(quoted) 2>/dev/null"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux:
            let commandName = backend.commandName
            let script = "$ErrorActionPreference = 'Stop'; & \(powerShellQuoted(commandName)) kill-session -t \(powerShellQuoted(sessionName)) 2>$null; exit $LASTEXITCODE"
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

    static func titlePropagationConfigLines() -> [String] {
        [
            "set -g allow-set-title on",
            "set -g set-titles on",
            "set -g set-titles-string \"#{pane_title}\""
        ]
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

    static func lifecycleMissingSessionCommand(backend: RemoteTmuxBackend) -> String {
        backend.isWindows ? "$null" : ":"
    }

}
