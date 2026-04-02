import Foundation

struct ConnectionViewTab: Identifiable, Hashable, Codable, Equatable {
    let id: String
    let localizedKey: String
    let icon: String

    static let stats = ConnectionViewTab(
        id: "stats",
        localizedKey: "Stats",
        icon: "chart.bar.xaxis"
    )

    static let terminal = ConnectionViewTab(
        id: "terminal",
        localizedKey: "Terminal",
        icon: "terminal"
    )

    static let files = ConnectionViewTab(
        id: "files",
        localizedKey: "Files",
        icon: "folder"
    )

    static let defaultOrder: [ConnectionViewTab] = [.stats, .terminal, .files]
    static let allTabs: [ConnectionViewTab] = defaultOrder

    static func from(id: String) -> ConnectionViewTab? {
        allTabs.first { $0.id == id }
    }
}
