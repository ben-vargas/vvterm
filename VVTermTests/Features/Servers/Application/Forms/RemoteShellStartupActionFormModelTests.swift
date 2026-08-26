import Foundation
import Testing
@testable import VVTerm

struct RemoteShellStartupActionFormModelTests {
    @Test
    func blankCommandDerivesNoStartupAction() throws {
        let model = RemoteShellStartupActionFormModel(action: nil)

        #expect(model.command.isEmpty)
        #expect(model.isValid)
        #expect(try model.makeAction() == nil)
    }

    @Test
    func commandBuildsOneRawStartupAction() throws {
        var model = RemoteShellStartupActionFormModel(action: nil)
        model.command = " cd ~/myproject && tmux attach "

        let optionalAction = try model.makeAction()
        let action = try #require(optionalAction)
        #expect(action.command == "cd ~/myproject && tmux attach")
    }

    @Test
    func validationIsDerivedFromTheCommand() {
        var model = RemoteShellStartupActionFormModel(action: nil)
        model.command = "printf ready\0"
        #expect(model.validationError == .invalidCommand)

        model.command = String(
            repeating: "x",
            count: RemoteShellStartupAction.maximumCommandByteCount + 1
        )
        #expect(model.validationError == .commandTooLong)
    }
}
