import Testing
@testable import VVTerm

struct CloudKitRecordChangeFetchIdentityTests {
    @Test
    func desiredKeyIdentityIgnoresOrderAndDuplicates() {
        #expect(
            CloudKitRecordChangeFetchIdentity(
                forceFullFetch: false,
                desiredKeys: ["name", "host", "name"]
            )
                == CloudKitRecordChangeFetchIdentity(
                    forceFullFetch: false,
                    desiredKeys: ["host", "name"]
                )
        )
    }

    @Test
    func sameRequestCoalesces() throws {
        let request = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: false,
            desiredKeys: ["host", "name"]
        )

        #expect(
            try CloudKitRecordChangeRequestPolicy.decision(
                for: request,
                inFlight: request
            ) == .coalesce
        )
    }

    @Test
    func differentDesiredKeysAreRejectedWhileRequestIsInFlight() {
        let inFlight = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: false,
            desiredKeys: ["name"]
        )
        let request = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: false,
            desiredKeys: ["name", "host"]
        )

        do {
            _ = try CloudKitRecordChangeRequestPolicy.decision(
                for: request,
                inFlight: inFlight
            )
            Issue.record("Expected incompatible change-stream request")
        } catch {
            #expect(error as? CloudKitRecordChangeStreamError == .incompatibleRequestInFlight)
        }
    }

    @Test
    func differentFetchModesAreRejectedWhileRequestIsInFlight() {
        let inFlight = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: false,
            desiredKeys: ["host", "name"]
        )
        let request = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: true,
            desiredKeys: ["host", "name"]
        )

        do {
            _ = try CloudKitRecordChangeRequestPolicy.decision(
                for: request,
                inFlight: inFlight
            )
            Issue.record("Expected incompatible change-stream request")
        } catch {
            #expect(error as? CloudKitRecordChangeStreamError == .incompatibleRequestInFlight)
        }
    }
}
