import Foundation

nonisolated struct OpenSourceAttribution: Decodable, Equatable, Identifiable, Sendable {
    enum Role: String, Decodable, Sendable {
        case terminalEngine
        case networkTransport
        case securityLibrary
        case archiveLibrary
        case machineLearningLibrary
        case utilityLibrary
        case sessionProtocol
        case speechModel
        case fontCollection
        case themeCollection
        case artwork
    }

    struct Document: Equatable, Identifiable, Sendable {
        let attribution: OpenSourceAttribution
        let legalText: String

        var id: String { attribution.id }
    }

    let id: String
    let name: String
    let role: Role
    let projectURL: URL
    let licenseName: String
    let licenseResource: String
}
