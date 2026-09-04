import Foundation

nonisolated extension RemoteTmuxCommandBuilder {
    static func windowsLaunchScript(for request: RemoteSessionLaunchRequest, backend: RemoteTmuxBackend) -> String {
        let name = request.attachment.identifier.rawValue
        switch request.intent {
        case .ensureManaged(_, let initialCommand):
            return windowsEnsureManagedPowerShell(
                sessionName: name, workingDirectory: request.workingDirectory,
                initialCommand: initialCommand, backend: backend, themeStyle: request.themeStyle,
                lifecycleEnvelope: request.lifecycleEnvelope
            )
        case .attach(let attachment):
            return windowsAttachExistingPowerShell(
                sessionName: name, missingCommand: lifecycleMissingSessionCommand(backend: backend),
                backend: backend, themeStyle: request.themeStyle,
                lifecycleEnvelope: request.lifecycleEnvelope, ownership: attachment.ownership
            )
        }
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
        let compatibilityCheck = requirePsmuxExtension ? """
        $vvtermCommands = (& $cmd.Source list-commands 2>$null) -join "`n"
        $vvtermAvailable = $vvtermCommands.Contains('dump-state') -or $vvtermCommands.Contains('claim-session')
        """ : "$vvtermAvailable = $true"
        let script = """
        $vvtermAvailable = $false
        $cmd = Get-Command \(powerShellQuoted(commandName)) -ErrorAction SilentlyContinue
        if ($cmd) {
          $vvtermVersions = @(& $cmd.Source -V 2>$null)
          if ($LASTEXITCODE -eq 0) {
            \(compatibilityCheck)
          }
        }
        if ($vvtermAvailable) {
          $vvtermVersion = $vvtermVersions | Select-Object -First 1
          Write-Output \(powerShellQuoted(availableMarker))
          Write-Output (\(powerShellQuoted("__VVTERM_TMUX_PATH__")) + $cmd.Source)
          Write-Output (\(powerShellQuoted("__VVTERM_TMUX_VERSION__")) + $vvtermVersion)
        } else {
          Write-Output \(powerShellQuoted(missingMarker))
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    static var windowsSessionListCompletion: String {
        "if ($LASTEXITCODE -eq 0) { Write-Output '\(sessionListSuccessMarker)' }"
    }

    static func windowsPsmuxListSessionsCommand(
        commandName: String,
        format: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions -F \(powerShellQuoted(format)) 2>$null; \(windowsSessionListCompletion)",
            backend: backend
        )
    }

    static func windowsEnsureManagedCommand(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String?,
        backend: RemoteTmuxBackend,
        themeStyle: RemoteSessionThemeStyle,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope?
    ) -> String {
        return windowsShellCommand(
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

    static func windowsAttachExistingCommand(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope?,
        themeStyle: RemoteSessionThemeStyle,
        reportsCreationFailure: Bool = false,
        requiresManagedMarker: Bool,
        ownership: RemoteSessionOwnership
    ) -> String {
        return windowsShellCommand(
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

    static func windowsEnsureManagedPowerShell(
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
            commandExpression: commandExpression,
            lifecycleEnvelope: lifecycleEnvelope
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
        let configurationCommand = usesManagedConfiguration
            ? "& $vvtermPsmux source-file -t $vvtermSession $vvtermConfig 2>$null"
            : ""
        let attachCommand = """
        \(configurationCommand)
        \(windowsAttachedReport(lifecycleEnvelope))
        & $vvtermPsmux -u attach-session -d -t $vvtermSession
        """
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

    private static func windowsCreateSessionPowerShell(
        sessionName: String,
        workingDirectory: String,
        initialCommand: String? = nil,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil,
        lifecycleEnvelope: RemoteSessionLifecycleEnvelope? = nil
    ) -> String {
        guard backend.isWindows else { return "" }
        let commandName = backend.commandName
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        let creationReportArguments = attachedMarker(lifecycleEnvelope).map { attached in
            return " -P -F \(powerShellQuoted(attached))"
        } ?? ""
        return """
        $vvtermPsmux = \(psmuxExpression)
        $vvtermConfig = \(windowsConfigPathPowerShellExpression())
        $vvtermSession = \(powerShellQuoted(sessionName))
        $vvtermWorkingDirectory = \(windowsWorkingDirectoryExpression(workingDirectory))
        & $vvtermPsmux -u -f $vvtermConfig new-session\(creationReportArguments) -s $vvtermSession -c $vvtermWorkingDirectory\(initialCommand.map { " " + powerShellQuoted($0) } ?? "")
        """
    }

    private static func windowsAttachedReport(
        _ lifecycleEnvelope: RemoteSessionLifecycleEnvelope?
    ) -> String {
        guard let attached = attachedMarker(lifecycleEnvelope) else { return "" }
        return "[Console]::Out.Write(\(powerShellQuoted(attached)))"
    }

    static func attachedMarker(
        _ lifecycleEnvelope: RemoteSessionLifecycleEnvelope?
    ) -> String? {
        lifecycleEnvelope.map {
            RemoteSessionLifecycleMarker.sequence(envelope: $0, event: .attached)
        }
    }

    static func windowsDefaultShellCommand(backend: RemoteTmuxBackend) -> String {
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

    static func windowsShellCommand(
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

    static func powerShellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    static func indentPowerShell(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : prefix + line
            }
            .joined(separator: "\n")
    }

}
