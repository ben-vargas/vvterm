import Foundation

nonisolated enum RemoteSessionStartupConflictPolicy {
    private enum Quote {
        case single
        case double
    }

    private static let sessionExecutables: Set<String> = [
        RemoteSessionBackendIdentifier.herdr.rawValue,
        RemoteSessionBackendIdentifier.tmux.rawValue,
        RemoteSessionBackendIdentifier.zellij.rawValue,
        RemoteSessionBackendIdentifier.zmx.rawValue,
        "pmux",
        "psmux"
    ]

    static func invokesSessionManager(in command: String) -> Bool {
        clauses(in: command).contains { clause in
            guard let executable = executable(in: clause) else { return false }
            return sessionExecutables.contains(executable)
        }
    }

    private static func executable(in words: [String]) -> String? {
        var remaining = words[...]
        while let first = remaining.first {
            if isAssignment(first) {
                remaining = remaining.dropFirst()
                continue
            }

            switch first.lowercased() {
            case "exec", "nohup", "command":
                remaining = remaining.dropFirst()
            case "env":
                remaining = remaining.dropFirst()
                while let argument = remaining.first,
                      argument.hasPrefix("-") || isAssignment(argument) {
                    remaining = remaining.dropFirst()
                }
            default:
                return normalizedExecutable(first)
            }
        }
        return nil
    }

    private static func normalizedExecutable(_ rawExecutable: String) -> String? {
        let pathComponents = rawExecutable
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
        guard var name = pathComponents.last.map(String.init)?.lowercased() else {
            return nil
        }
        if name.hasSuffix(".exe") {
            name.removeLast(4)
        }
        return name
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let separator = word.firstIndex(of: "="), separator != word.startIndex else {
            return false
        }
        let name = word[..<separator]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func clauses(in command: String) -> [[String]] {
        var result: [[String]] = []
        var words: [String] = []
        var word = ""
        var quote: Quote?
        var isEscaped = false

        func finishWord() {
            guard !word.isEmpty else { return }
            words.append(word)
            word.removeAll(keepingCapacity: true)
        }

        func finishClause() {
            finishWord()
            guard !words.isEmpty else { return }
            result.append(words)
            words.removeAll(keepingCapacity: true)
        }

        for character in command {
            if isEscaped {
                word.append(character)
                isEscaped = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    word.append(character)
                }
            case .double:
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    word.append(character)
                    isEscaped = true
                } else {
                    word.append(character)
                }
            case nil:
                if character == "'" {
                    quote = .single
                } else if character == "\"" {
                    quote = .double
                } else if character == "\\" {
                    word.append(character)
                    isEscaped = true
                } else if character.isWhitespace {
                    if character == "\n" || character == "\r" {
                        finishClause()
                    } else {
                        finishWord()
                    }
                } else if character == ";" || character == "&" || character == "|" {
                    finishClause()
                } else {
                    word.append(character)
                }
            }
        }
        finishClause()
        return result
    }
}
