import Foundation
import Testing
@testable import VVTerm

struct RemoteSessionLifecycleTests {
    @Test
    func existingSessionWithoutEventResolvesAsDetach() {
        let reason = TerminalShellEndReason.resolve(
            lifecycle: lifecycle(ownership: .managed),
            event: nil,
            sessionExists: true
        )

        #expect(reason == .remoteSessionDetached(.managed))
    }

    @Test
    func missingSessionWithoutEventResolvesAsTermination() {
        let reason = TerminalShellEndReason.resolve(
            lifecycle: lifecycle(ownership: .external),
            event: nil,
            sessionExists: false
        )

        #expect(reason == .remoteSessionTerminated(.external))
    }

    @Test
    func failedPresenceProbeIsAmbiguous() {
        let reason = TerminalShellEndReason.resolve(
            lifecycle: lifecycle(ownership: .managed),
            event: nil,
            sessionExists: nil
        )

        #expect(reason == .observationAmbiguous)
    }

    @Test
    func explicitFailuresRemainDistinct() {
        let lifecycle = lifecycle(ownership: .managed)

        #expect(TerminalShellEndReason.resolve(
            lifecycle: lifecycle,
            event: .creationFailed,
            sessionExists: false
        ) == .remoteSessionCreationFailed)
        #expect(TerminalShellEndReason.resolve(
            lifecycle: lifecycle,
            event: .attachFailed,
            sessionExists: true
        ) == .remoteSessionAttachFailed)
    }

    @Test
    func presenceProbeParsesOnlyItsPrivateMarkers() {
        let probe = RemoteSessionPresenceProbe(
            command: "probe",
            existsMarker: "private-exists",
            missingMarker: "private-missing"
        )

        #expect(probe.sessionExists(in: "private-exists") == true)
        #expect(probe.sessionExists(in: "private-missing") == false)
        #expect(probe.sessionExists(in: "unrelated output") == nil)
        #expect(probe.sessionExists(in: "private-exists private-missing") == nil)
    }

    @Test
    func removesBellTerminatedEvent() {
        let envelope = envelope(token: "test-token", operation: "11111111-1111-1111-1111-111111111111")
        var parser = RemoteSessionLifecycleStreamParser(envelope: envelope)
        let marker = RemoteSessionLifecycleMarker.sequence(
            envelope: envelope,
            event: .detached,
            terminator: .bell
        )

        let result = parser.consume(Data("before\(marker)after".utf8))

        #expect(String(decoding: result.output, as: UTF8.self) == "beforeafter")
        #expect(result.events == [.detached])
        #expect(parser.finish().isEmpty)
    }

    @Test
    func removesStringTerminatedEventSplitAcrossChunks() {
        let envelope = envelope(token: "split-token", operation: "22222222-2222-2222-2222-222222222222")
        var parser = RemoteSessionLifecycleStreamParser(envelope: envelope)
        let marker = Data(RemoteSessionLifecycleMarker.sequence(
            envelope: envelope,
            event: .terminated,
            terminator: .string
        ).utf8)
        let splitIndex = marker.index(marker.startIndex, offsetBy: marker.count / 2)

        let first = parser.consume(Data("visible".utf8) + marker[..<splitIndex])
        let second = parser.consume(marker[splitIndex...] + Data("tail".utf8))

        #expect(String(decoding: first.output, as: UTF8.self) == "visible")
        #expect(first.events.isEmpty)
        #expect(String(decoding: second.output, as: UTF8.self) == "tail")
        #expect(second.events == [.terminated])
        #expect(parser.finish().isEmpty)
    }

    @Test
    func preservesFramesWithWrongTokenOrOperation() {
        let expected = envelope(token: "expected", operation: "33333333-3333-3333-3333-333333333333")
        let wrongToken = envelope(token: "other", operation: expected.operationID.uuidString)
        let wrongOperation = envelope(token: expected.token, operation: "44444444-4444-4444-4444-444444444444")
        var parser = RemoteSessionLifecycleStreamParser(envelope: expected)
        let input = [wrongToken, wrongOperation].map {
            RemoteSessionLifecycleMarker.sequence(envelope: $0, event: .detached)
        }.joined()

        let result = parser.consume(Data(input.utf8))
        let remaining = parser.finish()

        #expect(String(decoding: result.output + remaining, as: UTF8.self) == input)
        #expect(result.events.isEmpty)
    }

    @Test
    func finishReturnsIncompleteFrameAsNormalOutput() {
        let envelope = envelope(token: "partial-token", operation: "55555555-5555-5555-5555-555555555555")
        var parser = RemoteSessionLifecycleStreamParser(envelope: envelope)
        let marker = RemoteSessionLifecycleMarker.sequence(envelope: envelope, event: .detached)
        let prefix = String(marker.prefix(marker.count - 4))

        let result = parser.consume(Data(prefix.utf8))
        let remaining = parser.finish()

        #expect(result.output.isEmpty)
        #expect(String(decoding: remaining, as: UTF8.self) == prefix)
        #expect(result.events.isEmpty)
    }

    @Test
    func largeUntrustedOutputDoesNotAccumulate() {
        let envelope = envelope(token: "bounded", operation: "66666666-6666-6666-6666-666666666666")
        var parser = RemoteSessionLifecycleStreamParser(envelope: envelope)
        let input = Data(repeating: 0x78, count: 1_000_000)

        let result = parser.consume(input)

        #expect(result.output == input)
        #expect(result.events.isEmpty)
        #expect(parser.finish().isEmpty)
    }

    @Test
    func legacyTmuxMarkersRemainHiddenAfterSnapshotMigration() throws {
        let token = "legacy-token"
        let observation = try RemoteSessionLifecycleObservation(
            legacyTmuxMarkerToken: token
        )
        var parser = RemoteSessionLifecycleStreamParser(observation: observation)
        let detached = "\u{001B}]777;vvterm-tmux;\(token);detached\u{0007}"
        let ended = "\u{001B}]777;vvterm-tmux;\(token);ended\u{0007}"

        let result = parser.consume(Data("before\(detached)middle\(ended)after".utf8))

        #expect(String(decoding: result.output, as: UTF8.self) == "beforemiddleafter")
        #expect(result.events == [.detached, .terminated])
        #expect(parser.finish().isEmpty)
    }

    private func lifecycle(ownership: RemoteSessionOwnership) -> RemoteSessionLifecycleContext {
        RemoteSessionLifecycleContext(
            attachment: RemoteSessionAttachment(
                identifier: try! RemoteSessionIdentifier(
                    backendIdentifier: .tmux,
                    validating: "test-session"
                ),
                ownership: ownership
            ),
            envelope: envelope(token: "token", operation: "77777777-7777-7777-7777-777777777777"),
            presenceProbe: RemoteSessionPresenceProbe(
                command: "probe",
                existsMarker: "exists",
                missingMarker: "missing"
            )
        )
    }

    private func envelope(token: String, operation: String) -> RemoteSessionLifecycleEnvelope {
        try! RemoteSessionLifecycleEnvelope(
            token: token,
            operationID: UUID(uuidString: operation)!
        )
    }
}
