import ETBootstrap
import ETSession
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class RecordingEternalTerminalOutputSink: EternalTerminalOutputSink {
    private(set) var output: [Data] = []

    func receiveEternalTerminalOutput(_ data: Data) {
        output.append(data)
    }
}

struct EternalTerminalSessionAdapterTests {
    @Test
    func vendorLifecycleMapsToApplicationOwnedState() {
        #expect(
            EternalTerminalVendorErrorMapper.state(for: .bootstrapping)
                == .bootstrapping
        )
        #expect(
            EternalTerminalVendorErrorMapper.state(
                for: .failed(.invalidKey("rejected"))
            ) == .failed(.invalidKey)
        )
        #expect(
            EternalTerminalVendorErrorMapper.state(
                for: .failed(.sessionUnrecoverable("history expired"))
            ) == .failed(.sessionUnrecoverable)
        )
    }

    @Test
    func vendorFailuresKeepTheirSemanticCategoryAndDiagnostic() {
        #expect(
            EternalTerminalVendorErrorMapper.failure(
                for: ETClientError.transportFailure("offline")
            ) == .transport
        )
        #expect(
            EternalTerminalVendorErrorMapper.failure(
                for: ETBootstrapError.markerNotFound("et daemon unavailable")
            ) == .bootstrapResponse("et daemon unavailable")
        )
        #expect(
            EternalTerminalVendorErrorMapper.failure(
                for: ETClientError.connectionClosed
            ) == .connectionClosed
        )
    }

    @Test @MainActor
    func semanticOutputSinkReceivesTerminalBytesWithoutVendorTypes() {
        let sink = RecordingEternalTerminalOutputSink()
        let output = Data("ready\r\n".utf8)

        sink.receiveEternalTerminalOutput(output)

        #expect(sink.output == [output])
    }
}
