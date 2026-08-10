import Foundation

typealias PendingCloudKitMutationPayload = PendingCloudKitPayloadEnvelope

protocol PendingCloudKitLegacyMutationMigrating {
    func migrate(
        recordData: Data
    ) -> Result<PendingCloudKitMutation, PendingCloudKitMutationQuarantineReason>?
}
