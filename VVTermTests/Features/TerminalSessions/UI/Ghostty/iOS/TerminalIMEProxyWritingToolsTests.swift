#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalIMEProxyWritingToolsTests {
    @Test
    func terminalOptsOutThroughUIKitInputTraits() throws {
        guard #available(iOS 18.0, *) else { return }
        let input = TerminalIMEProxyTextView(frame: .zero)
        let traits: any UITextInputTraits = input
        #expect(traits.writingToolsBehavior == UIWritingToolsBehavior.none)
    }
}
#endif
