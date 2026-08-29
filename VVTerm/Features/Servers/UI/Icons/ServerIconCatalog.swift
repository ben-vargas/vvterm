import SwiftUI

nonisolated enum ServerIconCatalog {
    static let genericIcons: [ServerIconID] = [
        .server,
        .cloud,
        .terminal,
        .code,
        .database,
        .storage,
        .container,
        .network,
        .shield,
        .homeLab,
        .web,
        .api,
        .compute,
        .cluster,
        .router,
        .automation,
        .monitoring,
        .backup,
        .media,
        .git,
        .artificialIntelligence,
        .virtualMachine,
    ]

    static let appleDeviceIcons: [ServerIconID] = [
        .macOS,
        .macBook,
        .macMini,
        .macStudio,
        .iMac,
        .macPro,
        .iPhone,
        .iPad,
        .appleTV,
        .homePod,
        .appleWatch,
    ]

    static let operatingSystemIcons: [ServerIconID] = [
        .linux,
        .ubuntu,
        .debian,
        .fedora,
        .redHat,
        .arch,
        .alpine,
        .openSUSE,
        .nixOS,
        .freeBSD,
        .openBSD,
        .netBSD,
        .windows,
    ]
}

extension ServerIconID {
    nonisolated var displayName: String {
        switch self {
        case .server: String(localized: "Server")
        case .cloud: String(localized: "Cloud")
        case .terminal: String(localized: "Terminal")
        case .code: String(localized: "Code")
        case .database: String(localized: "Database")
        case .storage: String(localized: "Storage")
        case .container: String(localized: "Container")
        case .network: String(localized: "Network")
        case .shield: String(localized: "Shield")
        case .homeLab: String(localized: "Home Lab")
        case .web: String(localized: "Web")
        case .api: "API"
        case .compute: String(localized: "Compute")
        case .cluster: String(localized: "Cluster")
        case .router: String(localized: "Router")
        case .automation: String(localized: "Automation")
        case .monitoring: String(localized: "Monitoring")
        case .backup: String(localized: "Backup")
        case .media: String(localized: "Media")
        case .git: "Git"
        case .artificialIntelligence: "AI"
        case .virtualMachine: String(localized: "Virtual Machine")
        case .macBook: "MacBook"
        case .macMini: "Mac mini"
        case .macStudio: "Mac Studio"
        case .iMac: "iMac"
        case .macPro: "Mac Pro"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .appleTV: "Apple TV"
        case .homePod: "HomePod"
        case .appleWatch: "Apple Watch"
        case .linux: "Linux"
        case .ubuntu: "Ubuntu"
        case .debian: "Debian"
        case .fedora: "Fedora"
        case .redHat: "Red Hat"
        case .arch: "Arch Linux"
        case .alpine: "Alpine Linux"
        case .openSUSE: "openSUSE"
        case .nixOS: "NixOS"
        case .macOS: "Mac"
        case .freeBSD: "FreeBSD"
        case .openBSD: "OpenBSD"
        case .netBSD: "NetBSD"
        case .windows: "Windows"
        }
    }

    nonisolated var systemImageName: String {
        switch self {
        case .server: "server.rack"
        case .cloud: "cloud"
        case .terminal: "terminal"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .database: "cylinder"
        case .storage: "internaldrive"
        case .container: "shippingbox"
        case .network: "network"
        case .shield: "shield"
        case .homeLab: "house"
        case .web: "globe"
        case .api: "curlybraces"
        case .compute: "cpu"
        case .cluster: "circle.grid.3x3"
        case .router: "wifi.router"
        case .automation: "gearshape.2"
        case .monitoring: "chart.xyaxis.line"
        case .backup: "externaldrive.badge.timemachine"
        case .media: "play.rectangle"
        case .git: "arrow.triangle.branch"
        case .artificialIntelligence: "brain"
        case .virtualMachine: "square.stack.3d.up"
        case .macBook:
            if #available(iOS 17.0, macOS 14.0, *) {
                "macbook"
            } else {
                "laptopcomputer"
            }
        case .macMini: "macmini"
        case .macStudio: "macstudio"
        case .iMac: "desktopcomputer"
        case .macPro: "macpro.gen3"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .appleTV: "appletv"
        case .homePod: "homepod"
        case .appleWatch: "applewatch"
        case .linux: "desktopcomputer"
        case .ubuntu: "circle.grid.cross"
        case .debian: "d.circle"
        case .fedora: "f.circle.fill"
        case .redHat: "hat.widebrim.fill"
        case .arch: "triangle.fill"
        case .alpine: "mountain.2.fill"
        case .openSUSE: "leaf.fill"
        case .nixOS: "snowflake"
        case .macOS: "desktopcomputer"
        case .freeBSD: "flame.fill"
        case .openBSD: "fish.fill"
        case .netBSD: "flag.fill"
        case .windows: "square.grid.2x2.fill"
        }
    }

    nonisolated var assetName: String? {
        switch self {
        case .linux: "ServerIconLinux"
        case .debian: "ServerIconDebian"
        case .nixOS: "ServerIconNixOS"
        default: nil
        }
    }
}

extension RemoteSystemKind {
    nonisolated var displayName: String {
        switch self {
        case .linux: "Linux"
        case .ubuntu: "Ubuntu"
        case .debian: "Debian"
        case .fedora: "Fedora"
        case .redHat: "Red Hat"
        case .arch: "Arch Linux"
        case .alpine: "Alpine Linux"
        case .openSUSE: "openSUSE"
        case .nixOS: "NixOS"
        case .macOS: "macOS"
        case .freeBSD: "FreeBSD"
        case .openBSD: "OpenBSD"
        case .netBSD: "NetBSD"
        case .windows: "Windows"
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension RemoteSystemIdentity {
    nonisolated var iconDisplayName: String {
        if kind == .macOS, let appleHardwareModelIdentifier {
            return appleHardwareModelIdentifier.iconDisplayName
        }
        return displayName ?? kind.displayName
    }
}

extension AppleHardwareModelIdentifier {
    nonisolated var iconDisplayName: String {
        if rawValue.hasPrefix("MacBookPro") {
            return "MacBook Pro"
        }
        if rawValue.hasPrefix("MacBookAir") {
            return "MacBook Air"
        }
        switch family {
        case .macBook: return "MacBook"
        case .macMini: return "Mac mini"
        case .macStudio: return "Mac Studio"
        case .iMac: return "iMac"
        case .macPro: return "Mac Pro"
        case .unknown: return "Mac"
        }
    }
}
