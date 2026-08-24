import Foundation
import Combine
import Testing
@testable import VVTerm

struct TerminalTeardownIntentTests {
    @Test
    func onlyApplicationTerminationPreservesReconnectableDescriptorsAndETCredentials() {
        for intent in TerminalTeardownIntent.allCases {
            let preservesReconnectableState = intent == .applicationTermination
            #expect(intent.removesPersistedDescriptor != preservesReconnectableState)
            #expect(intent.deletesResumableSessionState != preservesReconnectableState)
        }
    }

    @Test
    func onlyExplicitUserActionsTerminateManagedRemoteSessions() {
        #expect(TerminalTeardownIntent.explicitClose.terminatesManagedRemoteSession)
        #expect(TerminalTeardownIntent.explicitServerDisconnect.terminatesManagedRemoteSession)
        #expect(!TerminalTeardownIntent.remoteSessionEnded.terminatesManagedRemoteSession)
        #expect(!TerminalTeardownIntent.applicationTermination.terminatesManagedRemoteSession)
    }
}
