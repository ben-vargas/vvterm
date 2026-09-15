import Foundation

nonisolated extension TerminalComposerSendActions {
    static let preferenceKey = "terminalComposerSendActions"

    static func load(_ data: Data) throws -> Self {
        guard !data.isEmpty else { return .defaults }
        guard data.count <= 1_048_576 else { throw StorageError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.isValid else { throw StorageError.invalid }
        return value
    }

    func encoded() throws -> Data {
        guard isValid else { throw StorageError.invalid }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 1_048_576 else { throw StorageError.invalid }
        return data
    }

    enum StorageError: Error { case invalid }
}
