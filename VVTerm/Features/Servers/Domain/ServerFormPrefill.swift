import Foundation

nonisolated struct ServerFormPrefill: Equatable, Hashable, Sendable {
    var name: String
    var host: String
    var port: Int
    var username: String?

    init(
        name: String,
        host: String,
        port: Int = 22,
        username: String? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
    }
}
