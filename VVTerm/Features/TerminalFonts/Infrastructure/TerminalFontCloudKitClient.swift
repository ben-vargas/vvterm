import CloudKit
import Foundation
import os.log

@MainActor
final class TerminalFontCloudKitClient: TerminalFontCloudClient,
    TerminalFontCloudMutationClient {
    private let transport: any CloudKitRecordTransport
    private let repository: any TerminalFontAssetRepository
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "TerminalFontCloudKit"
    )

    init(
        transport: any CloudKitRecordTransport,
        repository: any TerminalFontAssetRepository
    ) {
        self.transport = transport
        self.repository = repository
    }

    func fetchTerminalFonts() async throws -> [TerminalFont] {
        let records = try await transport.fetchCloudKitRecords(
            matchingRecordTypes: [TerminalFontCloudKitRecordCodec.recordType],
            desiredKeys: TerminalFontCloudKitRecordCodec.metadataKeys
        )
        var fonts: [TerminalFont] = []

        for record in records {
            try Task.checkCancellation()
            guard let font = TerminalFontCloudKitRecordCodec.font(from: record) else {
                logger.warning("Ignored invalid terminal font CloudKit record")
                continue
            }
            if !font.isDeleted, repository.existingFileURL(for: font) == nil {
                do {
                    let assetRecord = try await transport.fetchCloudKitRecord(record.recordID)
                    guard let assetURL = TerminalFontCloudKitRecordCodec.assetURL(
                        from: assetRecord
                    ) else {
                        logger.warning("Synced font has no asset: \(font.displayName)")
                        fonts.append(font)
                        continue
                    }
                    try repository.installRemoteAsset(from: assetURL, for: font)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.warning(
                        "Could not install synced font \(font.displayName): \(error.localizedDescription)"
                    )
                }
            }
            fonts.append(font)
        }

        return fonts
    }

    func fetchTerminalFontPreference() async throws -> TerminalFontPreference? {
        let recordID = TerminalFontPreferenceCloudKitRecordCodec.recordID(
            in: transport.cloudKitRecordZoneID
        )
        do {
            let record = try await transport.fetchCloudKitRecord(recordID)
            guard let preference = TerminalFontPreferenceCloudKitRecordCodec.preference(
                from: record
            ) else {
                logger.warning("Ignored invalid terminal font preference CloudKit record")
                return nil
            }
            return preference
        } catch {
            guard transport.isCloudKitRecordMissing(error) else { throw error }
            return nil
        }
    }

    func saveTerminalFont(_ font: TerminalFont) async throws {
        let assetURL = font.isDeleted ? nil : repository.existingFileURL(for: font)
        if !font.isDeleted, assetURL == nil {
            throw TerminalFontValidationError.fileUnavailable
        }
        let record = TerminalFontCloudKitRecordCodec.record(
            for: font,
            assetURL: assetURL,
            in: transport.cloudKitRecordZoneID
        )
        try await transport.performCloudKitRecordMutation { [transport] in
            try await transport.upsertCloudKitRecord(record)
        }
    }

    func saveTerminalFontPreference(_ preference: TerminalFontPreference) async throws {
        let record = TerminalFontPreferenceCloudKitRecordCodec.record(
            for: preference,
            in: transport.cloudKitRecordZoneID
        )
        try await transport.performCloudKitRecordMutation { [transport] in
            try await transport.upsertCloudKitRecord(record)
        }
    }
}
