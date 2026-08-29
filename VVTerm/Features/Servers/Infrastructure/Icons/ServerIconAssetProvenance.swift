import Foundation

nonisolated struct ServerIconAssetProvenance: Equatable, Sendable {
    let iconID: ServerIconID
    let assetName: String
    let upstreamURL: URL
    let upstreamRevision: String
    let sha256: String
    let license: String
    let brandGuidelinesURL: URL
    let attribution: String
    let transformation: String
}

nonisolated enum ServerIconBundledAssets {
    static let provenance: [ServerIconAssetProvenance] = [
        ServerIconAssetProvenance(
            iconID: .linux,
            assetName: "ServerIconLinux",
            upstreamURL: URL(string: "https://github.com/simple-icons/simple-icons/blob/7801972bc6c3056c24acc8ae170a0f6dfd3c3904/icons/linux.svg")!,
            upstreamRevision: "Simple Icons 16.21.0 (7801972bc6c3056c24acc8ae170a0f6dfd3c3904)",
            sha256: "729a9d5cd5d92b8d3ee82ad2761d488558756336f13fc10e057b16f2cc2ef0f8",
            license: "CC0-1.0 for the normalized SVG; Tux use requires attribution",
            brandGuidelinesURL: URL(string: "https://www.kernel.org/faq.html#tux")!,
            attribution: "Tux by Larry Ewing, Simon Budig, and Garrett LeSage. Credit Larry Ewing and The GIMP.",
            transformation: "Added the catalog's Linux yellow fill; path geometry is unchanged."
        ),
        ServerIconAssetProvenance(
            iconID: .debian,
            assetName: "ServerIconDebian",
            upstreamURL: URL(string: "https://github.com/simple-icons/simple-icons/blob/7801972bc6c3056c24acc8ae170a0f6dfd3c3904/icons/debian.svg")!,
            upstreamRevision: "Simple Icons 16.21.0 (7801972bc6c3056c24acc8ae170a0f6dfd3c3904)",
            sha256: "7666830a69df09c18f5ec11a06e0236114cec3da3d6edea516a3e1cc2cfe0363",
            license: "CC0-1.0 for the normalized SVG; Debian Open Use Logo is LGPL-3.0-or-later OR CC-BY-SA-3.0",
            brandGuidelinesURL: URL(string: "https://www.debian.org/logos/")!,
            attribution: "Copyright 1999 Software in the Public Interest, Inc.",
            transformation: "Added Debian red fill; path geometry is unchanged."
        ),
        ServerIconAssetProvenance(
            iconID: .nixOS,
            assetName: "ServerIconNixOS",
            upstreamURL: URL(string: "https://github.com/simple-icons/simple-icons/blob/7801972bc6c3056c24acc8ae170a0f6dfd3c3904/icons/nixos.svg")!,
            upstreamRevision: "Simple Icons 16.21.0 (7801972bc6c3056c24acc8ae170a0f6dfd3c3904)",
            sha256: "ea19f68fd5e3d577192f5aa380015eaeeca39be89d96a1a8396824df653a1aaa",
            license: "CC0-1.0 for the normalized SVG; NixOS branding artwork is CC-BY-4.0",
            brandGuidelinesURL: URL(string: "https://nixos.org/branding/")!,
            attribution: "NixOS logomark by Simon Frankau and Tim Cuthbertson; normalized by Simple Icons.",
            transformation: "Added the official NixOS blue fill; path geometry is unchanged."
        ),
    ]
}
