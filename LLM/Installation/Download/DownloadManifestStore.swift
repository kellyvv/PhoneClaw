import Foundation

actor DownloadManifestStore {
    static let workspaceDirectoryName = ".downloads"
    static let manifestFileName = ".download-manifest.json"

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        BackgroundDownloadSession.shared.registerManifestRoot(rootDirectory)
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

    func resumeDataURL(for assetID: String, relativePath: String) throws -> URL {
        let url = try workspaceDirectory(for: assetID)
            .appendingPathComponent(relativePath, isDirectory: false)
            .appendingPathExtension("resumeData")
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
        let url = rawManifestURL(for: assetID)
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

    func resumeState(for assetID: String) throws -> DownloadResumeState? {
        guard let manifest = try readManifest(for: assetID) else { return nil }

        var downloadedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var hasUnknownTotal = false
        var resumableFileCount = 0

        for file in manifest.files where file.state != .complete {
            let partialURL = try partialFileURL(for: assetID, relativePath: file.relativePath)
            let partialBytes = fileSize(at: partialURL)
            let expectedBytes = file.metadata?.contentLength ?? file.expectedBytes
            let bytes = clampedResumeBytes(max(partialBytes, file.downloadedBytes), expectedBytes: expectedBytes)
            guard bytes > 0 else { continue }

            downloadedBytes += bytes
            resumableFileCount += 1

            if let expected = expectedBytes, expected > 0 {
                totalBytes += expected
            } else {
                hasUnknownTotal = true
            }
        }

        guard resumableFileCount > 0 else { return nil }
        return DownloadResumeState(
            downloadedBytes: downloadedBytes,
            totalBytes: hasUnknownTotal ? nil : totalBytes,
            resumableFileCount: resumableFileCount
        )
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

    private func rawWorkspaceDirectory(for assetID: String) -> URL {
        rootDirectory
            .appendingPathComponent(Self.workspaceDirectoryName, isDirectory: true)
            .appendingPathComponent(sanitizedAssetID(assetID), isDirectory: true)
    }

    private func rawManifestURL(for assetID: String) -> URL {
        rawWorkspaceDirectory(for: assetID)
            .appendingPathComponent(Self.manifestFileName, isDirectory: false)
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return 0
        }
        return (attributes[.size] as? Int64) ?? 0
    }

    private func clampedResumeBytes(_ bytes: Int64, expectedBytes: Int64?) -> Int64 {
        let positiveBytes = max(0, bytes)
        guard let expectedBytes, expectedBytes > 0 else { return positiveBytes }
        return min(positiveBytes, expectedBytes)
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
