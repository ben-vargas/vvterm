import Testing
@testable import VVTerm

struct ServerDuplicateNamePolicyTests {
    @Test
    func unusedBaseNameIsReturnedWithoutASequenceNumber() {
        #expect(
            ServerDuplicateNamePolicy.uniqueName(
                baseName: "Production Copy",
                existingNames: ["Production"]
            ) == "Production Copy"
        )
    }

    @Test
    func firstAvailableSequenceNumberIsUsedCaseInsensitively() {
        #expect(
            ServerDuplicateNamePolicy.uniqueName(
                baseName: "Production Copy",
                existingNames: [
                    "production copy",
                    "Production Copy 2",
                    "Production Copy 4"
                ]
            ) == "Production Copy 3"
        )
    }
}
