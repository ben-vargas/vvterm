import Foundation

nonisolated struct RemoteShellStartupActionFormModel: Equatable, Sendable {
    enum ValidationError: Equatable, Sendable {
        case invalidCommand
        case commandTooLong
    }

    var command: String

    init(action: RemoteShellStartupAction?) {
        command = action?.command ?? ""
    }

    var validationError: ValidationError? {
        do {
            _ = try makeAction()
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

    var isValid: Bool {
        validationError == nil
    }

    func makeAction() throws -> RemoteShellStartupAction? {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try RemoteShellStartupAction(command: command)
    }
}
