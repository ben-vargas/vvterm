import Foundation

enum RemoteShellFamily: String, Hashable, Sendable {
    case posix
    case powershell
    case cmd
    case unknown
}

struct RemoteShellProfile: Hashable, Sendable {
    let family: RemoteShellFamily
    let executableName: String?
    let shellName: String?

    var supportsPOSIXExecWrapper: Bool {
        family == .posix
    }

    var supportsPowerShellCommands: Bool {
        family == .powershell
    }

    var supportsOSC7Reporting: Bool {
        switch family {
        case .posix:
            return true
        case .powershell, .cmd, .unknown:
            return false
        }
    }

    func launchPlan(startupCommand: String?, bundle: Bundle = .main) -> RemoteShellLaunchPlan {
        let trimmed = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch family {
        case .posix:
            guard !trimmed.isEmpty else {
                let script = RemoteTerminalBootstrap.prefixedPOSIXScript(
                    for: RemoteTerminalBootstrap.defaultLoginShellCommand(),
                    bundle: bundle
                )
                return .exec(RemoteTerminalBootstrap.wrapPOSIXShellCommand(script))
            }
            let script = RemoteTerminalBootstrap.prefixedPOSIXScript(for: trimmed, bundle: bundle)
            return .exec(RemoteTerminalBootstrap.wrapPOSIXShellCommand(script))
        case .powershell:
            guard !trimmed.isEmpty else {
                return .shell
            }
            let executable = executableName ?? "powershell"
            let script = RemoteTerminalBootstrap.prefixedPowerShellScript(for: trimmed, bundle: bundle)
            return .exec(RemoteTerminalBootstrap.wrapPowerShellCommand(script, executableName: executable))
        case .cmd:
            guard !trimmed.isEmpty else {
                return .shell
            }
            return .exec(RemoteTerminalBootstrap.wrapCmdCommand(trimmed))
        case .unknown:
            guard !trimmed.isEmpty else {
                return .shell
            }
            return .shell
        }
    }

    func directoryChangeCommand(for path: String) -> String {
        switch family {
        case .posix:
            return RemoteTerminalBootstrap.posixDirectoryChangeCommand(for: path)
        case .powershell:
            return RemoteTerminalBootstrap.powerShellDirectoryChangeCommand(for: path)
        case .cmd:
            return RemoteTerminalBootstrap.cmdDirectoryChangeCommand(for: path)
        case .unknown:
            return "\n"
        }
    }

    static func posix(shellName: String?) -> RemoteShellProfile {
        RemoteShellProfile(family: .posix, executableName: shellName, shellName: shellName)
    }

    static func powershell(executableName: String?) -> RemoteShellProfile {
        let shellName = executableName?.lowercased()
        return RemoteShellProfile(family: .powershell, executableName: executableName, shellName: shellName)
    }

    static var cmd: RemoteShellProfile {
        RemoteShellProfile(family: .cmd, executableName: "cmd.exe", shellName: "cmd.exe")
    }

    static func unknown(shellName: String? = nil) -> RemoteShellProfile {
        RemoteShellProfile(family: .unknown, executableName: shellName, shellName: shellName)
    }
}

struct RemoteEnvironment: Hashable, Sendable {
    let platform: RemotePlatform
    let shellProfile: RemoteShellProfile
    let activeShellName: String?
    let powerShellExecutable: String?

    var supportsTmuxRuntime: Bool {
        platform != .windows && shellProfile.family == .posix
    }

    var supportsMoshRuntime: Bool {
        platform != .windows && shellProfile.family == .posix
    }

    var supportsWorkingDirectoryRestore: Bool {
        switch shellProfile.family {
        case .posix, .powershell, .cmd:
            return true
        case .unknown:
            return false
        }
    }

    static let fallbackPOSIX = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "sh"),
        activeShellName: "sh",
        powerShellExecutable: nil
    )
}

enum RemoteEnvironmentResolver {
    private static let probeTimeout: Duration = .seconds(2)

    static func resolve(using client: SSHClient) async -> RemoteEnvironment {
        let platform = await detectPlatform(using: client)

        switch platform {
        case .windows:
            let powerShellExecutable = await detectPowerShellExecutable(using: client)
            let activeShell = await detectWindowsShell(using: client)
            let profile: RemoteShellProfile
            switch activeShell {
            case .powershell:
                profile = .powershell(executableName: powerShellExecutable)
            case .cmd:
                profile = .cmd
            case .unknown:
                profile = .unknown(shellName: nil)
            case .posix:
                profile = .posix(shellName: nil)
            }
            return RemoteEnvironment(
                platform: .windows,
                shellProfile: profile,
                activeShellName: profile.shellName,
                powerShellExecutable: powerShellExecutable
            )

        case .linux, .darwin, .freebsd, .openbsd, .netbsd, .unknown:
            let shellName = await detectUnixShellName(using: client)
            let profile = resolveUnixProfile(shellName: shellName)
            return RemoteEnvironment(
                platform: platform,
                shellProfile: profile,
                activeShellName: shellName,
                powerShellExecutable: nil
            )
        }
    }

    private static func detectPlatform(using client: SSHClient) async -> RemotePlatform {
        if let output = await probe("cmd.exe /d /c ver", using: client) {
            let platform = RemotePlatform.detect(from: output)
            if platform == .windows {
                return .windows
            }
        }

        if let output = await probe("uname -s", using: client) {
            return RemotePlatform.detect(from: output)
        }

        if let output = await probe(
            RemoteTerminalBootstrap.wrapPOSIXShellCommand("/usr/bin/uname -s 2>/dev/null || /bin/uname -s 2>/dev/null || uname -s"),
            using: client
        ) {
            return RemotePlatform.detect(from: output)
        }

        return .unknown
    }

    private static func detectUnixShellName(using client: SSHClient) async -> String? {
        let probes = [
            #"printf '%s' "$SHELL" 2>/dev/null"#,
            #"ps -p $$ -o comm= 2>/dev/null"#,
        ]

        for command in probes {
            guard let output = await probe(command, using: client) else { continue }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = (trimmed as NSString).lastPathComponent.lowercased()
            return normalized.isEmpty ? nil : normalized
        }

        return nil
    }

    private static func resolveUnixProfile(shellName: String?) -> RemoteShellProfile {
        guard let shellName else {
            return .posix(shellName: "sh")
        }

        switch shellName {
        case "bash", "zsh", "sh", "dash", "ksh", "ash", "fish", "elvish":
            return .posix(shellName: shellName)
        case "nu", "nushell":
            return .posix(shellName: shellName)
        default:
            return .posix(shellName: shellName)
        }
    }

    private static func detectPowerShellExecutable(using client: SSHClient) async -> String? {
        let marker = "__VVTERM_PWSH_OK__"
        for executable in ["powershell", "pwsh"] {
            if let output = await probe("cmd.exe /d /c where \(executable)", using: client),
               output.lowercased().contains(executable) {
                return executable
            }

            if let output = await probe("where \(executable)", using: client),
               output.lowercased().contains(executable) {
                return executable
            }

            let command = RemoteTerminalBootstrap.wrapPowerShellCommand("Write-Output '\(marker)'", executableName: executable)
            guard let output = await probe(command, using: client) else { continue }
            if output.contains(marker) {
                return executable
            }
        }
        return nil
    }

    private static func detectWindowsShell(using client: SSHClient) async -> RemoteShellFamily {
        if let output = await probe(#"reg query "HKLM\SOFTWARE\OpenSSH" /v DefaultShell"#, using: client) {
            let normalized = output.lowercased()
            if normalized.contains("powershell") || normalized.contains("pwsh") {
                return .powershell
            }
            if normalized.contains("cmd.exe") {
                return .cmd
            }
        }

        let powerShellMarker = "__VVTERM_ACTIVE_POWERSHELL__"
        if let output = await probe("Write-Output '\(powerShellMarker)'", using: client),
           output.contains(powerShellMarker) {
            return .powershell
        }

        let cmdMarker = "__VVTERM_ACTIVE_CMD__"
        if let output = await probe("for %I in (1) do @echo \(cmdMarker)", using: client),
           output.contains(cmdMarker) {
            return .cmd
        }

        return .unknown
    }

    private static func probe(_ command: String, using client: SSHClient) async -> String? {
        try? await client.execute(command, timeout: probeTimeout)
    }
}
