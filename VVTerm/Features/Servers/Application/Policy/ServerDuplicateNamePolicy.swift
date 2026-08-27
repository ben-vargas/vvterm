import Foundation

nonisolated struct ServerDuplicateNamePolicy: Sendable {
    static func uniqueName(
        baseName: String,
        existingNames: [String]
    ) -> String {
        let normalizedNames = Set(existingNames.map(normalized))
        guard normalizedNames.contains(normalized(baseName)) else {
            return baseName
        }

        let lastSuffix = UInt64(existingNames.count) + 2
        for suffix in UInt64(2)...lastSuffix {
            let candidate = "\(baseName) \(suffix)"
            if !normalizedNames.contains(normalized(candidate)) {
                return candidate
            }
        }

        // The loop checks more candidates than there are existing names.
        preconditionFailure("A unique server name must be available")
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale.current)
    }
}
