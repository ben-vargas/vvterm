import Foundation

nonisolated struct TerminalFont: Identifiable, Codable, Equatable, Sendable {
    typealias ID = String

    enum FileFormat: String, CaseIterable, Sendable {
        case ttf
        case otf
        case ttc
        case otc

        init?(fileExtension: String) {
            self.init(rawValue: fileExtension.lowercased())
        }
    }

    let familyNames: [String]
    let originalFilename: String
    let fileSize: Int64
    let sha256: String
    var updatedAt: Date
    var deletedAt: Date?

    init(
        familyNames: [String],
        originalFilename: String,
        fileSize: Int64,
        sha256: String,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.familyNames = familyNames
        self.originalFilename = originalFilename
        self.fileSize = fileSize
        self.sha256 = sha256.lowercased()
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var displayName: String {
        familyNames.first ?? originalFilename
    }

    var id: String {
        sha256
    }

    var isDeleted: Bool {
        deletedAt != nil
    }
}
