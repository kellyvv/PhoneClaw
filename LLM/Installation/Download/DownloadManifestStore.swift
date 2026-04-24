import Foundation

actor DownloadManifestStore {
    static let workspaceDirectoryName = ".downloads"
    static let manifestFileName = ".download-manifest.json"

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func workspaceRootDirectory() throws -> URL {
        let url = rootDirectory.appendingPathComponent(Self.workspaceDirectoryName, isDirectory: true)
        try ensureDirectory(url, excludedFromBackup: true)
        return url
    }

    func workspaceDirectory(for assetID: String) throws -> URL {
        let url = try workspaceRootDirectory()
            .appendingPathComponent(sanitizedAssetID(assetID), isDirectory: true)
        try ensureDirectory(url, excludedFromBackup: true)
        return url
    }

    func manifestURL(for assetID: String) throws -> URL {
        try workspaceDirectory(for: assetID)
            .appendingPathComponent(Self.manifestFileName, isDirectory: false)
    }

    func partialFileURL(for assetID: String, relativePath: String) throws -> URL {
        let url = try workspaceDirectory(for: assetID)
            .appendingPathComponent(relativePath, isDirectory: false)
            .appendingPathExtension("part")
        try ensureDirectory(url.deletingLastPathComponent(), excludedFromBackup: true)
        return url
    }

    func stagingDirectory(for assetID: String) throws -> URL {
        let url = try workspaceDirectory(for: assetID)
            .appendingPathComponent("staging", isDirectory: true)
        try ensureDirectory(url, excludedFromBackup: true)
        return url
    }

    func readManifest(for assetID: String) throws -> DownloadManifest? {
        let url = try manifestURL(for: assetID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder.downloadManifestDecoder.decode(DownloadManifest.self, from: data)
            guard manifest.schemaVersion <= DownloadManifest.currentSchemaVersion else {
                throw DownloadFailure.manifestCorrupt(
                    "schema v\(manifest.schemaVersion) > v\(DownloadManifest.currentSchemaVersion)"
                )
            }
            return manifest
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure.manifestCorrupt(error.localizedDescription)
        }
    }

    func writeManifest(_ manifest: DownloadManifest, for assetID: String) throws {
        let url = try manifestURL(for: assetID)
        let data = try JSONEncoder.downloadManifestEncoder.encode(manifest)
        try atomicWrite(data, to: url)
    }

    func purge(assetID: String) throws {
        let url = try workspaceDirectory(for: assetID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func pruneOrphans(knownAssetIDs: Set<String>) throws {
        let workspaceRoot = try workspaceRootDirectory()
        let knownDirectoryNames = Set(knownAssetIDs.map(sanitizedAssetID))
        guard let children = try? fileManager.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            guard !knownDirectoryNames.contains(child.lastPathComponent) else { continue }
            try fileManager.removeItem(at: child)
        }
    }

    private func ensureDirectory(_ url: URL, excludedFromBackup: Bool) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        guard excludedFromBackup else { return }
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func atomicWrite(_ data: Data, to destinationURL: URL) throws {
        let parentDirectory = destinationURL.deletingLastPathComponent()
        try ensureDirectory(parentDirectory, excludedFromBackup: true)

        let temporaryURL = parentDirectory
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporaryURL, options: [.completeFileProtectionUntilFirstUserAuthentication])
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw DownloadFailure.fileSystem(error.localizedDescription)
        }
    }

    private func sanitizedAssetID(_ assetID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = assetID.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "_"
        }
        let sanitized = scalars.joined()
        return sanitized.isEmpty ? "asset" : sanitized
    }
}

extension JSONEncoder {
    static var downloadManifestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var downloadManifestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
