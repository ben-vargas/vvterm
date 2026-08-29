import Foundation
import Testing
@testable import VVTerm

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ServerIconPresentationTests {
    @Test
    func manualSelectionAlwaysWinsOverDetection() {
        let identity = RemoteSystemIdentity(kind: .ubuntu, displayName: "Ubuntu")

        #expect(
            ServerIconPresentationResolver.presentation(
                selection: .custom(.database),
                detectedSystemIdentity: identity
            ) == .systemImage("cylinder")
        )
    }

    @Test
    func automaticSelectionUsesDetectedSystem() {
        let identity = RemoteSystemIdentity(kind: .debian, displayName: "Debian")

        #expect(
            ServerIconPresentationResolver.presentation(
                selection: .automatic,
                detectedSystemIdentity: identity
            ) == .asset("ServerIconDebian")
        )
    }

    @Test
    func restrictedLinuxBrandUsesSimilarSystemSymbol() {
        let identity = RemoteSystemIdentity(kind: .ubuntu, displayName: "Ubuntu 24.04 LTS")

        #expect(
            ServerIconPresentationResolver.presentation(
                selection: .automatic,
                detectedSystemIdentity: identity
            ) == .systemImage("circle.grid.cross")
        )
        #expect(identity.iconDisplayName == "Ubuntu 24.04 LTS")
    }

    @Test
    func automaticMacUsesModelArtworkWithFamilyFallback() throws {
        let model = try #require(AppleHardwareModelIdentifier(rawValue: "MacBookPro18,3"))
        let identity = RemoteSystemIdentity(
            kind: .macOS,
            appleHardwareModelIdentifier: model
        )

        #expect(
            ServerIconPresentationResolver.presentation(
                selection: .automatic,
                detectedSystemIdentity: identity
            ) == .appleDevice(
                modelIdentifier: model,
                fallbackSystemImage: ServerIconID.macBook.systemImageName
            )
        )
    }

    @Test
    func customAppleDeviceUsesItsSpecificSystemSymbol() {
        #expect(
            ServerIconPresentationResolver.presentation(
                selection: .custom(.macStudio),
                detectedSystemIdentity: nil
            ) == .systemImage("macstudio")
        )
    }

    @Test
    func automaticUnknownModelUsesGenericMacFallback() throws {
        let model = try #require(AppleHardwareModelIdentifier(rawValue: "FutureComputer1,1"))
        let identity = RemoteSystemIdentity(
            kind: .macOS,
            appleHardwareModelIdentifier: model
        )

        #expect(
            ServerIconPresentationResolver.presentation(
                selection: .automatic,
                detectedSystemIdentity: identity
            ) == .appleDevice(
                modelIdentifier: model,
                fallbackSystemImage: "desktopcomputer"
            )
        )
    }

    @Test
    func automaticMacProUsesMacProFamilyFallback() throws {
        let model = try #require(AppleHardwareModelIdentifier(rawValue: "MacPro7,1"))
        let identity = RemoteSystemIdentity(
            kind: .macOS,
            appleHardwareModelIdentifier: model
        )

        #expect(
            ServerIconPresentationResolver.presentation(
                selection: .automatic,
                detectedSystemIdentity: identity
            ) == .appleDevice(
                modelIdentifier: model,
                fallbackSystemImage: ServerIconID.macPro.systemImageName
            )
        )
    }

    @Test
    func macModelUsesSpecificFamilyDisplayName() throws {
        let macBookPro = try #require(
            AppleHardwareModelIdentifier(rawValue: "MacBookPro18,3")
        )
        let macStudio = try #require(
            AppleHardwareModelIdentifier(rawValue: "Mac14,13")
        )

        #expect(macBookPro.iconDisplayName == "MacBook Pro")
        #expect(macStudio.iconDisplayName == "Mac Studio")
    }

    @Test
    func catalogIdentifiersAreUniqueAndProvenanceIsComplete() {
        let catalog = ServerIconCatalog.genericIcons
            + ServerIconCatalog.appleDeviceIcons
            + ServerIconCatalog.operatingSystemIcons

        #expect(Set(catalog).count == catalog.count)
        #expect(Set(catalog) == Set(ServerIconID.allCases))
        #expect(ServerIconCatalog.genericIcons.count == 22)
        #expect(
            ServerIconCatalog.appleDeviceIcons == [
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
        )
        #expect(
            ServerIconCatalog.operatingSystemIcons == [
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
        )

        let provenanceAssetNames = Set(
            ServerIconBundledAssets.provenance.map(\.assetName)
        )
        let catalogAssetNames = Set(catalog.compactMap(\.assetName))
        #expect(catalogAssetNames.isSubset(of: provenanceAssetNames))
        #expect(provenanceAssetNames.count == ServerIconBundledAssets.provenance.count)

        for provenance in ServerIconBundledAssets.provenance {
            #expect(provenance.iconID.assetName == provenance.assetName)
            #expect(provenance.sha256.count == 64)
            #expect(!provenance.license.isEmpty)
            #expect(!provenance.attribution.isEmpty)
        }
    }

    @Test
    func bundledCatalogAssetsExist() {
        for provenance in ServerIconBundledAssets.provenance {
            #if os(macOS)
            #expect(NSImage(named: provenance.assetName) != nil)
            #elseif os(iOS)
            #expect(UIImage(named: provenance.assetName) != nil)
            #endif
        }
    }
}
