import Foundation

nonisolated struct RemoteSessionCommandPlan: Codable, Hashable, Sendable {
    let executable: RemoteSessionExecutable
    let arguments: [String]
    let environment: [String: String]
    let environmentRemovals: Set<String>
    let workingDirectory: String?

    init(
        executable: RemoteSessionExecutable,
        arguments: [String] = [],
        environment: [String: String] = [:],
        environmentRemovals: Set<String> = [],
        workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.environmentRemovals = environmentRemovals
        self.workingDirectory = workingDirectory
    }
}

nonisolated enum RemoteSessionCommandRenderer {
    enum RenderError: Error, Equatable, Sendable {
        case unsupportedShell
        case invalidEnvironmentName
        case invalidValue
        case tooManyArguments
        case tooManyEnvironmentValues
        case commandTooLong
    }

    private static let maximumArgumentCount = 256
    private static let maximumEnvironmentValueCount = 128
    private static let maximumInputBytes = 64 * 1_024
    private static let maximumRenderedCommandBytes = 128 * 1_024

    static func render(
        _ plan: RemoteSessionCommandPlan,
        for shellFamily: RemoteShellFamily
    ) throws -> String {
        try validate(plan)
        let command = switch shellFamily {
        case .posix:
            renderPOSIX(plan)
        case .powershell:
            renderPowerShell(plan)
        case .cmd:
            try renderCommandPrompt(plan)
        case .unknown:
            throw RenderError.unsupportedShell
        }
        guard command.utf8.count <= maximumRenderedCommandBytes else {
            throw RenderError.commandTooLong
        }
        return command
    }

    private static func validate(_ plan: RemoteSessionCommandPlan) throws {
        guard plan.arguments.count <= maximumArgumentCount else {
            throw RenderError.tooManyArguments
        }
        let (environmentValueCount, environmentCountOverflow) = plan.environment.count
            .addingReportingOverflow(plan.environmentRemovals.count)
        guard !environmentCountOverflow,
              environmentValueCount <= maximumEnvironmentValueCount else {
            throw RenderError.tooManyEnvironmentValues
        }
        let values = plan.arguments + Array(plan.environment.values) + [plan.workingDirectory].compactMap { $0 }
        guard values.allSatisfy({
            $0.utf8.count <= 16_384
                && $0.rangeOfCharacter(from: .controlCharacters.subtracting(CharacterSet(charactersIn: "\t"))) == nil
        }) else {
            throw RenderError.invalidValue
        }
        let environmentNames = Set(plan.environment.keys).union(plan.environmentRemovals)
        guard environmentNames.allSatisfy({ key in
            guard let first = key.unicodeScalars.first,
                  CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
                return false
            }
            return key.unicodeScalars.dropFirst().allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
            }
        }) else {
            throw RenderError.invalidEnvironmentName
        }
        let inputValues = values
            + Array(plan.environment.keys)
            + Array(plan.environmentRemovals)
            + [plan.executable.path]
        var inputBytes = 0
        for value in inputValues {
            let (total, overflow) = inputBytes.addingReportingOverflow(value.utf8.count)
            guard !overflow, total <= maximumInputBytes else {
                throw RenderError.commandTooLong
            }
            inputBytes = total
        }
    }

    private static func renderPOSIX(_ plan: RemoteSessionCommandPlan) -> String {
        let removals = plan.environmentRemovals.sorted().flatMap { ["-u", $0] }
        let environment = plan.environment.keys.sorted().map { key in
            "\(key)=\(RemoteTerminalBootstrap.shellQuoted(plan.environment[key] ?? ""))"
        }
        let invocation = ([RemoteTerminalBootstrap.shellQuoted(plan.executable.path)]
            + plan.arguments.map(RemoteTerminalBootstrap.shellQuoted))
            .joined(separator: " ")
        let commandPrefix = removals.isEmpty
            ? environment
            : ["env"] + removals.map(RemoteTerminalBootstrap.shellQuoted) + environment
        let command = (commandPrefix + [invocation]).joined(separator: " ")
        guard let workingDirectory = plan.workingDirectory else { return command }
        return "cd \(RemoteTerminalBootstrap.shellQuoted(workingDirectory)) && \(command)"
    }

    private static func renderPowerShell(_ plan: RemoteSessionCommandPlan) -> String {
        var statements = plan.environmentRemovals.sorted().map { key in
            "Remove-Item Env:\(key) -ErrorAction SilentlyContinue"
        }
        statements.append(contentsOf: plan.environment.keys.sorted().map { key in
            "$env:\(key) = \(powerShellQuoted(plan.environment[key] ?? ""))"
        })
        if let workingDirectory = plan.workingDirectory {
            statements.append("Set-Location -LiteralPath \(powerShellQuoted(workingDirectory))")
        }
        let arguments = plan.arguments.map(powerShellQuoted).joined(separator: " ")
        statements.append("& \(powerShellQuoted(plan.executable.path))\(arguments.isEmpty ? "" : " \(arguments)")")
        return statements.joined(separator: "; ")
    }

    private static func renderCommandPrompt(
        _ plan: RemoteSessionCommandPlan
    ) throws -> String {
        let script = renderPowerShell(plan)
        guard let data = script.data(using: .utf16LittleEndian) else {
            throw RenderError.invalidValue
        }
        return "powershell.exe -NoLogo -NoProfile -EncodedCommand \(data.base64EncodedString())"
    }

    private static func powerShellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
