import Foundation

nonisolated enum ServerIconID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case server
    case cloud
    case terminal
    case code
    case database
    case storage
    case container
    case network
    case shield
    case homeLab = "home_lab"
    case web
    case api
    case compute
    case cluster
    case router
    case automation
    case monitoring
    case backup
    case media
    case git
    case artificialIntelligence = "ai"
    case virtualMachine = "virtual_machine"
    case macBook = "macbook"
    case macMini = "mac_mini"
    case macStudio = "mac_studio"
    case iMac = "imac"
    case macPro = "mac_pro"
    case iPhone = "iphone"
    case iPad = "ipad"
    case appleTV = "apple_tv"
    case homePod = "homepod"
    case appleWatch = "apple_watch"
    case linux
    case ubuntu
    case debian
    case fedora
    case redHat = "red_hat"
    case arch
    case alpine
    case openSUSE = "opensuse"
    case nixOS = "nixos"
    case macOS = "macos"
    case freeBSD = "freebsd"
    case openBSD = "openbsd"
    case netBSD = "netbsd"
    case windows

    var id: String { rawValue }

    static func automaticIcon(for kind: RemoteSystemKind) -> Self {
        switch kind {
        case .linux: .linux
        case .ubuntu: .ubuntu
        case .debian: .debian
        case .fedora: .fedora
        case .redHat: .redHat
        case .arch: .arch
        case .alpine: .alpine
        case .openSUSE: .openSUSE
        case .nixOS: .nixOS
        case .macOS: .macOS
        case .freeBSD: .freeBSD
        case .openBSD: .openBSD
        case .netBSD: .netBSD
        case .windows: .windows
        case .unknown: .server
        }
    }
}
