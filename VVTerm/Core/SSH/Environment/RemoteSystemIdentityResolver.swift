import Foundation

nonisolated enum RemoteSystemIdentityResolver {
    struct WindowsSystemInformation: Equatable, Sendable {
        let caption: String
        let version: String
        let productType: Int
    }

    private static let windowsCaptionMarker = "__VVTERM_WINDOWS_CAPTION__="
    private static let windowsVersionMarker = "__VVTERM_WINDOWS_VERSION__="
    private static let windowsProductTypeMarker = "__VVTERM_WINDOWS_PRODUCT_TYPE__="

    static func resolve(
        environment: RemoteEnvironment,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async -> RemoteSystemIdentity? {
        guard !Task.isCancelled else { return nil }

        switch environment.platform {
        case .linux:
            let output = await probe(linuxOSReleaseCommand(), execute: execute)
            guard !Task.isCancelled else { return nil }
            return output.map(parseLinuxOSRelease)
                ?? RemoteSystemIdentity(kind: .linux)

        case .darwin:
            let modelOutput = await probe(appleHardwareModelCommand(), execute: execute)
            guard !Task.isCancelled else { return nil }
            let model = modelOutput.flatMap(AppleHardwareModelIdentifier.init(rawValue:))
            return RemoteSystemIdentity(
                kind: .macOS,
                displayName: "macOS",
                appleHardwareModelIdentifier: model
            )

        case .freebsd:
            return RemoteSystemIdentity(kind: .freeBSD, displayName: "FreeBSD")
        case .openbsd:
            return RemoteSystemIdentity(kind: .openBSD, displayName: "OpenBSD")
        case .netbsd:
            return RemoteSystemIdentity(kind: .netBSD, displayName: "NetBSD")

        case .windows:
            if let executable = environment.powerShellExecutable {
                let output = await probe(
                    windowsCIMCommand(powerShellExecutable: executable),
                    execute: execute
                )
                guard !Task.isCancelled else { return nil }
                if let output, let information = parseWindowsCIMOutput(output) {
                    return RemoteSystemIdentity(
                        kind: .windows,
                        displayName: information.caption
                    )
                }
            }

            _ = await probe("cmd.exe /d /c ver", execute: execute)
            guard !Task.isCancelled else { return nil }
            return RemoteSystemIdentity(kind: .windows, displayName: "Windows")

        case .unknown:
            return nil
        }
    }

    nonisolated static func linuxOSReleaseCommand() -> String {
        RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            "if [ -r /etc/os-release ]; then cat /etc/os-release; "
                + "elif [ -r /usr/lib/os-release ]; then cat /usr/lib/os-release; fi"
        )
    }

    nonisolated static func appleHardwareModelCommand() -> String {
        "/usr/sbin/sysctl -n hw.model"
    }

    nonisolated static func windowsCIMCommand(powerShellExecutable: String) -> String {
        let script = """
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property Caption,Version,ProductType
        Write-Output ('\(windowsCaptionMarker)' + [string]$os.Caption)
        Write-Output ('\(windowsVersionMarker)' + [string]$os.Version)
        Write-Output ('\(windowsProductTypeMarker)' + [string]$os.ProductType)
        """
        return RemoteTerminalBootstrap.wrapPowerShellCommand(
            script,
            executableName: powerShellExecutable
        )
    }

    nonisolated static func parseLinuxOSRelease(_ output: String) -> RemoteSystemIdentity {
        let values = parseOSReleaseValues(output)
        let identifier = values["ID"]?.lowercased() ?? ""
        let kind: RemoteSystemKind = switch identifier {
        case "ubuntu": .ubuntu
        case "debian": .debian
        case "fedora": .fedora
        case "rhel", "redhat", "centos", "rocky", "almalinux": .redHat
        case "arch", "archlinux": .arch
        case "alpine": .alpine
        case "opensuse", "opensuse-leap", "opensuse-tumbleweed", "sles": .openSUSE
        case "nixos": .nixOS
        default: .linux
        }
        return RemoteSystemIdentity(
            kind: kind,
            displayName: values["PRETTY_NAME"] ?? values["NAME"]
        )
    }

    nonisolated static func parseWindowsCIMOutput(_ output: String) -> WindowsSystemInformation? {
        let values = output.split(whereSeparator: \Character.isNewline).reduce(
            into: [String: String]()
        ) { result, rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in [windowsCaptionMarker, windowsVersionMarker, windowsProductTypeMarker]
            where line.hasPrefix(marker) {
                result[marker] = String(line.dropFirst(marker.count))
            }
        }
        guard
            let caption = values[windowsCaptionMarker],
            !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let version = values[windowsVersionMarker],
            !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let productTypeValue = values[windowsProductTypeMarker],
            let productType = Int(productTypeValue),
            (1...3).contains(productType)
        else {
            return nil
        }
        return WindowsSystemInformation(
            caption: caption,
            version: version,
            productType: productType
        )
    }

    private nonisolated static func parseOSReleaseValues(_ output: String) -> [String: String] {
        output.split(whereSeparator: \Character.isNewline).reduce(into: [:]) { result, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                return
            }
            let key = line[..<separator]
            guard !key.isEmpty, key.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else {
                return
            }
            let rawValue = line[line.index(after: separator)...]
            guard result[String(key)] == nil, let value = parseOSReleaseValue(rawValue) else {
                return
            }
            result[String(key)] = value
        }
    }

    private nonisolated static func parseOSReleaseValue(_ rawValue: Substring) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard let first = value.first else { return "" }
        guard first == "\"" || first == "'" else {
            return value
        }
        guard value.count >= 2, value.last == first else { return nil }

        let contents = value.dropFirst().dropLast()
        guard first == "\"" else { return String(contents) }

        var result = ""
        var isEscaping = false
        for character in contents {
            if isEscaping {
                if character == "\"" || character == "\\" || character == "$" || character == "`" {
                    result.append(character)
                } else {
                    result.append("\\")
                    result.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        if isEscaping {
            result.append("\\")
        }
        return result
    }

    private static func probe(
        _ command: String,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        do {
            let output = try await execute(command, RemoteEnvironmentResolver.probeTimeout)
            guard !Task.isCancelled else { return nil }
            return output
        } catch {
            return nil
        }
    }
}
