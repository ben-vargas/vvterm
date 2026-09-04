import CloudKit

nonisolated enum CloudKitErrorClassifier {
    static func isMissingItem(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }

        switch cloudKitError.code {
        case .unknownItem, .zoneNotFound:
            return true
        case .partialFailure:
            guard let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: Error] else {
                return false
            }
            return partialErrors.values.contains(where: isMissingItem)
        default:
            return false
        }
    }
}
