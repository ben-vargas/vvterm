import Foundation

nonisolated struct RemoteShellStartupActionFormModel: Equatable, Sendable {
    enum ValidationError: Equatable, Sendable {
        case invalidCommand
        case commandTooLong
        case startsAnotherPersistentSession
    }

    var command: String

    init(action: RemoteShellStartupAction?) {
        command = action?.command ?? ""
    }

    func validationError(remoteSessionEnabled: Bool) -> ValidationError? {
        do {
            let action = try makeAction()
            if remoteSessionEnabled,
               let action,
               RemoteSessionStartupConflictPolicy.invokesSessionManager(
                   in: action.command
               ) {
                return .startsAnotherPersistentSession
            }
            return nil
        } catch let error as RemoteShellStartupAction.ValidationError {
            return switch error {
            case .empty:
                nil
            case .containsUnsupportedControlCharacters:
                .invalidCommand
            case .tooLong:
                .commandTooLong
            }
        } catch {
            return .invalidCommand
        }
    }

    func isValid(remoteSessionEnabled: Bool) -> Bool {
        validationError(remoteSessionEnabled: remoteSessionEnabled) == nil
    }

    func makeAction() throws -> RemoteShellStartupAction? {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try RemoteShellStartupAction(command: command)
    }

    func commandForPersistence() -> String? {
        do {
            return try makeAction()?.command
        } catch {
            return nil
        }
    }
}
