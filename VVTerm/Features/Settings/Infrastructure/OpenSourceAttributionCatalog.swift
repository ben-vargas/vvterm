import Foundation

nonisolated enum OpenSourceAttributionCatalog {
    enum CatalogError: Error, Equatable {
        case missingManifest
        case unsupportedSchemaVersion(Int)
        case emptyManifest
        case duplicateID(String)
        case invalidEntry(String)
        case missingLicenseResource(String)
        case emptyLicenseResource(String)
    }

    static let bundled: [OpenSourceAttribution.Document] = {
        do {
            return try load(from: .main)
        } catch {
            assertionFailure("Unable to load open-source attributions: \(error)")
            return []
        }
    }()

    static func load(from bundle: Bundle) throws -> [OpenSourceAttribution.Document] {
        guard let manifestURL = resourceURL(
            named: "Attributions",
            extension: "json",
            subdirectories: ["OpenSource", "Resources/OpenSource"],
            in: bundle
        ) else {
            throw CatalogError.missingManifest
        }

        return try load(manifestURL: manifestURL) { resource in
            resourceURL(
                named: (resource as NSString).deletingPathExtension,
                extension: (resource as NSString).pathExtension,
                subdirectories: ["OpenSource/Licenses", "Resources/OpenSource/Licenses"],
                in: bundle
            )
        }
    }

    static func load(
        manifestURL: URL,
        licenseDirectoryURL: URL
    ) throws -> [OpenSourceAttribution.Document] {
        try load(manifestURL: manifestURL) { resource in
            licenseDirectoryURL.appendingPathComponent(resource, isDirectory: false)
        }
    }

    private static func load(
        manifestURL: URL,
        licenseURL: (String) -> URL?
    ) throws -> [OpenSourceAttribution.Document] {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1 else {
            throw CatalogError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard !manifest.attributions.isEmpty else {
            throw CatalogError.emptyManifest
        }

        var ids = Set<String>()
        return try manifest.attributions.map { attribution in
            guard ids.insert(attribution.id).inserted else {
                throw CatalogError.duplicateID(attribution.id)
            }
            guard isValid(attribution) else {
                throw CatalogError.invalidEntry(attribution.id)
            }
            guard let url = licenseURL(attribution.licenseResource),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw CatalogError.missingLicenseResource(attribution.licenseResource)
            }

            let legalText = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            guard !legalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CatalogError.emptyLicenseResource(attribution.licenseResource)
            }
            return OpenSourceAttribution.Document(
                attribution: attribution,
                legalText: legalText
            )
        }
    }

    private static func isValid(_ attribution: OpenSourceAttribution) -> Bool {
        let resource = attribution.licenseResource as NSString
        return !attribution.id.isEmpty
            && !attribution.name.isEmpty
            && !attribution.licenseName.isEmpty
            && attribution.projectURL.scheme == "https"
            && attribution.projectURL.host != nil
            && resource.lastPathComponent == attribution.licenseResource
            && resource.pathExtension.lowercased() == "txt"
    }

    private static func resourceURL(
        named name: String,
        extension fileExtension: String,
        subdirectories: [String],
        in bundle: Bundle
    ) -> URL? {
        for subdirectory in subdirectories {
            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return bundle.url(forResource: name, withExtension: fileExtension)
    }
}

private nonisolated struct Manifest: Decodable {
    let schemaVersion: Int
    let attributions: [OpenSourceAttribution]
}
