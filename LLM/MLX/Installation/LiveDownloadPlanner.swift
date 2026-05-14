import Foundation

struct LiveAssetDownloadPlan: Sendable {
    let liveAsset: LiveModelAsset
    let files: [DownloadFile]
    let listingHost: String

    var totalBytes: Int64? {
        var total: Int64 = 0
        for file in files {
            guard let expectedSize = file.expectedSize else { return nil }
            total += expectedSize
        }
        return total
    }

    func downloadAsset(
        destinationDirectory: URL,
        preservesWorkspaceOnCompletion: Bool = false
    ) -> DownloadAsset {
        DownloadAsset(
            id: liveAsset.id,
            displayName: liveAsset.displayName,
            destinationDirectory: destinationDirectory,
            files: files,
            preservesWorkspaceOnCompletion: preservesWorkspaceOnCompletion
        )
    }
}

enum LiveDownloadPlanner {
    private static let hosts = [
        "hf-mirror.com",
        "huggingface.co"
    ]
    private static let treeRequestTimeout: TimeInterval = 12

    static func makePlans(for assets: [LiveModelAsset]) async throws -> [LiveAssetDownloadPlan] {
        var plans: [LiveAssetDownloadPlan] = []
        for asset in assets {
            plans.append(try await makePlan(for: asset))
        }
        return plans
    }

    static func makePlan(for asset: LiveModelAsset) async throws -> LiveAssetDownloadPlan {
        var lastError: Error?

        for host in hosts {
            do {
                // 1. 拉 repo tree (full repo paths, 包含可能的 prefix)
                // 2. 用 LiveModelDefinition.localPath(...) 把每个 entry 映射成 (remote, local) tuple,
                //    不在 prefix 范围内的返回 nil 被过滤掉
                // 3. 应用 excludePatterns (按 remote path 判断 — patterns 是 repo 相对的)
                // 4. validateRequiredFiles 用 local path 校验 (asset.requiredFiles 是 local 相对)
                let scoped: [(remote: String, local: String, size: Int64?)] = try await fetchTree(host: host, repo: asset.repositoryID)
                    .compactMap { repoFile -> (remote: String, local: String, size: Int64?)? in
                        guard let local = LiveModelDefinition.localPath(forRepository: repoFile.path, in: asset) else {
                            return nil
                        }
                        guard LiveModelDefinition.shouldDownload(repoFile.path, for: asset) else {
                            return nil
                        }
                        return (remote: repoFile.path, local: local, size: repoFile.size)
                    }
                    .sorted { $0.local < $1.local }

                try validateRequiredLocalFiles(asset, scoped: scoped)
                try assertNoNativeBinaryDownloads(asset: asset, scoped: scoped)

                guard !scoped.isEmpty else {
                    throw DownloadFailure.invalidResponse("\(asset.id) has no downloadable files")
                }

                let downloadFiles = scoped.map { entry in
                    DownloadFile(
                        relativePath: entry.local,
                        expectedSize: normalizedExpectedSize(entry.size),
                        sources: downloadSources(for: asset, remoteFile: entry.remote)
                    )
                }

                print("[LiveDL] \(host): \(asset.id) planned \(downloadFiles.count) files")
                return LiveAssetDownloadPlan(
                    liveAsset: asset,
                    files: downloadFiles,
                    listingHost: host
                )
            } catch {
                lastError = error
                print("[LiveDL] \(host) tree API failed for \(asset.id): \(error.localizedDescription)")
            }
        }

        throw lastError ?? DownloadFailure.invalidResponse("Unable to list \(asset.id)")
    }

    /// 用 local 相对路径校验 requiredFiles (asset.requiredFiles 写的是 local 路径,
    /// 即 prefix 已剥掉的版本)。
    private static func validateRequiredLocalFiles(
        _ asset: LiveModelAsset,
        scoped: [(remote: String, local: String, size: Int64?)]
    ) throws {
        let localPaths = scoped.map(\.local)
        let missing = asset.requiredFiles.filter { required in
            !localPathsContain(required, in: localPaths)
        }
        guard missing.isEmpty else {
            throw DownloadFailure.invalidResponse(
                "\(asset.id) repository schema changed; missing required files: \(missing.joined(separator: ", "))"
            )
        }
    }

    private static func localPathsContain(_ requiredPath: String, in paths: [String]) -> Bool {
        if paths.contains(where: { $0 == requiredPath }) {
            return true
        }
        let directoryPrefix = requiredPath.hasSuffix("/") ? requiredPath : "\(requiredPath)/"
        return paths.contains { $0.hasPrefix(directoryPrefix) }
    }

    // MARK: - App Store 红线防御
    //
    // App Store Review Guidelines 2.5.2 禁止下载并执行可执行代码 (native binary)。
    // Live 模型清单从 HF tree API 动态发现 — 如果 repo 里夹带 .framework / .dylib / .so 等,
    // 这里 fail-fast,避免被下到本地后试图加载导致拒包。
    // 见 docs/RUNTIME_ARCHITECTURE_PLAN.md §10.3。

    private static let forbiddenDownloadExtensions: [String] = [
        ".framework", ".xcframework", ".dylib", ".so", ".a", ".bundle"
    ]

    private static func assertNoNativeBinaryDownloads(
        asset: LiveModelAsset,
        scoped: [(remote: String, local: String, size: Int64?)]
    ) throws {
        for entry in scoped {
            let lowered = entry.local.lowercased()
            for ext in forbiddenDownloadExtensions where lowered.hasSuffix(ext) {
                let detail = "LiveModelAsset[\(asset.id)] HF tree returned native binary '\(entry.remote)'. " +
                             "Native runtime (frameworks/dylibs) must ship with the App, not be downloaded. " +
                             "See App Store Review Guidelines 2.5.2 / RUNTIME_ARCHITECTURE_PLAN.md §10.3."
                assertionFailure(detail)
                throw DownloadFailure.invalidResponse(detail)
            }
        }
    }

    private static func fetchTree(host: String, repo: String) async throws -> [RepositoryFile] {
        do {
            let files = try await fetchTreeRecursiveQuery(host: host, repo: repo)
            if !files.isEmpty {
                return files
            }
        } catch {
            print("[LiveDL] \(host) recursive tree API unavailable for \(repo): \(error.localizedDescription)")
        }
        return try await fetchTreeByWalkingDirectories(host: host, repo: repo, path: "")
    }

    private static func fetchTreeRecursiveQuery(host: String, repo: String) async throws -> [RepositoryFile] {
        guard let url = URL(string: "https://\(host)/api/models/\(repo)/tree/main?recursive=true") else {
            throw DownloadFailure.invalidURL("https://\(host)/api/models/\(repo)/tree/main?recursive=true")
        }

        let items = try await fetchTreeItems(url: url)
        return items.compactMap { item in
            guard item.type == "file" else { return nil }
            return RepositoryFile(path: item.path, size: item.size)
        }
    }

    private static func fetchTreeByWalkingDirectories(host: String, repo: String, path: String) async throws -> [RepositoryFile] {
        let urlPath = path.isEmpty
            ? "https://\(host)/api/models/\(repo)/tree/main"
            : "https://\(host)/api/models/\(repo)/tree/main/\(encodedPath(path))"

        guard let url = URL(string: urlPath) else {
            throw DownloadFailure.invalidURL(urlPath)
        }

        let items = try await fetchTreeItems(url: url)
        var files: [RepositoryFile] = []
        for item in items {
            if item.type == "file" {
                files.append(RepositoryFile(path: item.path, size: item.size))
            } else if item.type == "directory" {
                let subFiles = try await fetchTreeByWalkingDirectories(host: host, repo: repo, path: item.path)
                files.append(contentsOf: subFiles)
            }
        }
        return files
    }

    private static func fetchTreeItems(url: URL) async throws -> [TreeItem] {
        var request = URLRequest(url: url)
        request.timeoutInterval = treeRequestTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadFailure.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadFailure.httpStatus(http.statusCode)
        }

        return try JSONDecoder().decode([TreeItem].self, from: data)
    }

    private static func validateRequiredFiles(
        _ asset: LiveModelAsset,
        repositoryFiles: [RepositoryFile]
    ) throws {
        let missing = asset.requiredFiles.filter { required in
            !repositoryContains(required, in: repositoryFiles)
        }
        guard missing.isEmpty else {
            throw DownloadFailure.invalidResponse(
                "\(asset.id) repository schema changed; missing required files: \(missing.joined(separator: ", "))"
            )
        }
    }

    private static func repositoryContains(_ requiredPath: String, in files: [RepositoryFile]) -> Bool {
        if files.contains(where: { $0.path == requiredPath }) {
            return true
        }
        let directoryPrefix = requiredPath.hasSuffix("/") ? requiredPath : "\(requiredPath)/"
        return files.contains { $0.path.hasPrefix(directoryPrefix) }
    }

    /// 拼下载 URL 用 **repository 相对路径** (含 prefix), 跟 HF 上文件实际位置对应。
    private static func downloadSources(
        for asset: LiveModelAsset,
        remoteFile: String,
        sourceOrder: [String] = hosts
    ) -> [DownloadFile.Source] {
        sourceOrder.enumerated().compactMap { index, host in
            let encodedFile = encodedPath(remoteFile)
            guard let url = URL(string: "https://\(host)/\(asset.repositoryID)/resolve/main/\(encodedFile)") else {
                return nil
            }
            return DownloadFile.Source(label: host, url: url, priority: index)
        }
    }

    private static func encodedPath(_ path: String) -> String {
        path.components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
    }

    private static func normalizedExpectedSize(_ size: Int64?) -> Int64? {
        guard let size, size > 0 else { return nil }
        return size
    }

    private struct TreeItem: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    private struct RepositoryFile: Sendable {
        let path: String
        let size: Int64?
    }

}
