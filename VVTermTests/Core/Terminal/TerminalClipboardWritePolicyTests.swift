import Testing
@testable import VVTerm

struct TerminalClipboardWritePolicyTests {
    @Test
    func localCopyWritesImmediately() {
        #expect(
            TerminalClipboardWritePolicy.action(requiresConfirmation: false)
                == .writeImmediately
        )
    }

    @Test
    func remoteRequestedWriteRequiresConfirmation() {
        #expect(
            TerminalClipboardWritePolicy.action(requiresConfirmation: true)
                == .requestConfirmation
        )
    }
}
