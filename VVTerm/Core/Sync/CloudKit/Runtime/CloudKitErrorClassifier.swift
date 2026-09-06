import CloudKit

nonisolated enum CloudKitErrorClassifier {
    static func isMissingItem(_ error: Error) -> Bool {
        contains(error, codes: [.unknownItem, .zoneNotFound])
    }

    static func isMissingZone(_ error: Error) -> Bool {
        contains(error, codes: [.unknownItem, .zoneNotFound, .userDeletedZone])
    }

    // Numeric codes are safe to log; error descriptions can contain user data.
    static func diagnosticCodes(_ error: Error) -> [Int] {
        guard let cloudKitError = error as? CKError else { return [] }
        return [cloudKitError.code.rawValue] + partialErrors(cloudKitError).flatMap(diagnosticCodes)
    }

    private static func contains(_ error: Error, codes: Set<CKError.Code>) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        if codes.contains(cloudKitError.code) { return true }
        return partialErrors(cloudKitError).contains { contains($0, codes: codes) }
    }

    private static func partialErrors(_ error: CKError) -> [Error] {
        guard error.code == .partialFailure,
              let errors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else {
            return []
        }
        return Array(errors.values)
    }
}
