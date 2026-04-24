import Foundation

@main
struct DownloadManifestStoreTest {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phoneclaw-download-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DownloadManifestStore(rootDirectory: root)
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let metadata = DownloadFileMetadata(
            sourceURL: URL(string: "https://example.com/model.litertlm"),
            sourceHost: "example.com",
            etag: "\"abc123\"",
            contentLength: 42,
            lastModified: "Fri, 24 Apr 2026 00:00:00 GMT",
            checksumSHA256: "0123456789abcdef",
            updatedAt: now
        )
        let manifest = DownloadManifest(
            assetID: "gemma-4-e2b",
            createdAt: now,
            updatedAt: now,
            files: [
                DownloadManifestFile(
                    relativePath: "gemma-4-E2B-it.litertlm",
                    state: .downloading,
                    downloadedBytes: 21,
                    expectedBytes: 42,
                    selectedSourceLabel: "primary",
                    metadata: metadata
                )
            ]
        )

        try await store.writeManifest(manifest, for: manifest.assetID)
        guard let decodedManifest = try await store.readManifest(for: manifest.assetID) else {
            fatalError("Expected manifest to round-trip")
        }
        precondition(decodedManifest == manifest, "Manifest JSON round-trip changed data")

        let completedManifest = DownloadManifest(
            assetID: manifest.assetID,
            createdAt: now,
            updatedAt: Date(timeIntervalSince1970: 1_777_000_060),
            files: [
                DownloadManifestFile(
                    relativePath: "gemma-4-E2B-it.litertlm",
                    state: .complete,
                    downloadedBytes: 42,
                    expectedBytes: 42,
                    selectedSourceLabel: "primary",
                    metadata: metadata
                )
            ]
        )
        try await store.writeManifest(completedManifest, for: completedManifest.assetID)
        guard let decodedCompletedManifest = try await store.readManifest(for: completedManifest.assetID) else {
            fatalError("Expected overwritten manifest to round-trip")
        }
        precondition(
            decodedCompletedManifest == completedManifest,
            "Overwritten manifest JSON round-trip changed data"
        )

        let metadataData = try JSONEncoder.downloadManifestEncoder.encode(metadata)
        let decodedMetadata = try JSONDecoder.downloadManifestDecoder.decode(DownloadFileMetadata.self, from: metadataData)
        precondition(decodedMetadata == metadata, "Metadata JSON round-trip changed data")

        let workspaceRoot = try await store.workspaceRootDirectory()
        precondition(
            FileManager.default.fileExists(atPath: workspaceRoot.path),
            ".downloads workspace root should be created"
        )

        _ = try await store.workspaceDirectory(for: "stale-asset")
        _ = try await store.workspaceDirectory(for: "gemma-4-e2b")
        try await store.pruneOrphans(knownAssetIDs: ["gemma-4-e2b"])
        precondition(
            FileManager.default.fileExists(
                atPath: workspaceRoot.appendingPathComponent("gemma-4-e2b", isDirectory: true).path
            ),
            "Known asset workspace should be kept"
        )
        let staleURL = workspaceRoot.appendingPathComponent("stale-asset", isDirectory: true)
        precondition(
            !FileManager.default.fileExists(atPath: staleURL.path),
            "Unknown asset workspace should be pruned"
        )

        print("DownloadManifestStore tests passed")
    }
}
