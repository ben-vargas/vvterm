import Foundation
import Testing
@testable import VVTerm

struct TerminalFontTests {
    @Test
    func mergeUsesDigestIdentityAndKeepsNewestTombstone() throws {
        let old = font(updatedAt: Date(timeIntervalSince1970: 10))
        var deleted = font(updatedAt: Date(timeIntervalSince1970: 20))
        deleted.deletedAt = deleted.updatedAt

        let merged = TerminalFontMergePolicy.merge(local: [old], remote: [deleted])

        #expect(merged == [deleted])
    }

    @Test
    func validationRejectsUnsupportedMetadata() {
        let invalid = TerminalFont(
            familyNames: [],
            originalFilename: "font.ttf",
            fileSize: 10,
            sha256: String(repeating: "a", count: 64)
        )

        #expect(throws: TerminalFontValidationError.invalidMetadata) {
            try TerminalFontValidator.validateStoredFont(invalid)
        }
    }

    @Test
    func preferenceUsesNilForAutomaticCJK() {
        let preference = TerminalFontPreference(
            primaryFamily: " Menlo ",
            cjkFamily: "   ",
            updatedAt: .distantPast
        )

        #expect(preference.primaryFamily == "Menlo")
        #expect(preference.cjkFamily == nil)
    }

    private func font(updatedAt: Date) -> TerminalFont {
        TerminalFont(
            familyNames: ["Test Font"],
            originalFilename: "TestFont.ttf",
            fileSize: 1_024,
            sha256: String(repeating: "a", count: 64),
            updatedAt: updatedAt
        )
    }
}
