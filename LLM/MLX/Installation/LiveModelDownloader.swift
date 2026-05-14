import Foundation

// MARK: - LIVE Model Downloader
//
// 手机端按需下载 ASR + TTS 模型，合并为一个 "LIVE 语音模型" 下载体验。
// 完全独立于 LLM 的 ModelDownloader — 不修改 MLXLocalLLMService 的任何代码。
// 下载源: hf-mirror.com (国内优先) → huggingface.co (需 VPN)
// 注: 不走 modelscope.cn (csukuangfj/ 的 repo 在 ModelScope 上 404)

@Observable
class LiveModelDownloader {

    private(set) var installState: ModelInstallState = .notInstalled
    private(set) var downloadMetrics: ModelDownloadMetrics?
    private var currentTask: Task<Void, Never>?

    // MARK: - Download Source Hosts

    private static let hosts = [
        "hf-mirror.com",
        "huggingface.co"
    ]

    // MARK: - Public API

    var isAvailable: Bool {
        LiveModelDefinition.isAvailable
    }

    func refreshState() {
        cleanupStalePartials()
        if LiveModelDefinition.isAvailable {
            installState = .downloaded
        } else if case .downloading = installState {
            // 下载中不覆盖
        } else if case .checkingSource = installState {
            // 检查中不覆盖
        } else {
            installState = .notInstalled
        }
    }

    func downloadAll() async {
        guard currentTask == nil else { return }
        if isAvailable {
            refreshState()
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let modelsRoot = ModelPaths.documentsRoot()

            await MainActor.run {
                self.installState = .checkingSource
            }

            do {
                if !fm.fileExists(atPath: modelsRoot.path) {
                    try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
                }

                let assets = LiveModelDefinition.all

                // Phase 1: 使用 HF API 获取所有资产的完整文件列表
                var allFiles: [(asset: LiveModelAsset, files: [String])] = []
                for asset in assets {
                    // 跳过已就绪的资产
                    if LiveModelDefinition.resolve(for: asset) != nil {
                        continue
                    }
                    let files = try await listRepoFiles(for: asset)
                    allFiles.append((asset, files))
                }

                let totalFiles = allFiles.reduce(0) { $0 + $1.files.count }
                var globalFileIndex = 0

                // Phase 2: 逐个资产、逐个文件下载
                for (asset, files) in allFiles {
                    let partialDir = LiveModelDefinition.partialDirectory(for: asset)
                    let finalDir = LiveModelDefinition.downloadedDirectory(for: asset)

                    if fm.fileExists(atPath: partialDir.path) {
                        try fm.removeItem(at: partialDir)
                    }
                    try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)

                    for file in files {
                        try Task.checkCancellation()

                        let sources = Self.downloadSources(for: asset, file: file)
                        guard !sources.isEmpty else {
                            throw DownloadError.invalidURL(file)
                        }

                        await MainActor.run {
                            let displayFile = file.components(separatedBy: "/").last ?? file
                            self.installState = .downloading(
                                completedFiles: globalFileIndex,
                                totalFiles: totalFiles,
                                currentFile: displayFile
                            )
                            self.downloadMetrics = .init(
                                bytesReceived: 0,
                                totalBytes: nil,
                                bytesPerSecond: nil,
                                sourceLabel: sources.first?.label
                            )
                        }

                        var downloadedResult: (URL, URLResponse)?
                        var lastError: Error?

                        for source in sources {
                            try Task.checkCancellation()

                            await MainActor.run {
                                self.downloadMetrics = .init(
                                    bytesReceived: 0,
                                    totalBytes: nil,
                                    bytesPerSecond: nil,
                                    sourceLabel: source.label
                                )
                            }

                            let request = URLRequest(
                                url: source.url,
                                cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: 1800
                            )
                            let startTime = Date()

                            do {
                                let client = DownloadTaskClient(progressHandler: { [weak self] received, expected in
                                    let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
                                    let bytesPerSecond = Double(received) / elapsed
                                    Task { @MainActor [weak self] in
                                        self?.downloadMetrics = .init(
                                            bytesReceived: received,
                                            totalBytes: expected,
                                            bytesPerSecond: bytesPerSecond,
                                            sourceLabel: source.label
                                        )
                                    }
                                })
                                let result = try await client.start(request: request)

                                guard let http = result.1 as? HTTPURLResponse else {
                                    lastError = DownloadError.invalidResponse
                                    continue
                                }
                                guard (200...299).contains(http.statusCode) else {
                                    lastError = DownloadError.httpStatus(http.statusCode)
                                    PCLog.debug("[LiveDL] \(source.label) \(file): HTTP \(http.statusCode), trying next")
                                    continue
                                }
                                downloadedResult = result
                                break
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                lastError = error
                                PCLog.debug("[LiveDL] \(source.label) \(file): \(error.localizedDescription), trying next")
                            }
                        }

                        guard let (temporaryURL, _) = downloadedResult else {
                            throw lastError ?? DownloadError.invalidResponse
                        }

                        let destinationURL = partialDir.appendingPathComponent(file)
                        let parentDir = destinationURL.deletingLastPathComponent()
                        if !fm.fileExists(atPath: parentDir.path) {
                            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                        }
                        if fm.fileExists(atPath: destinationURL.path) {
                            try fm.removeItem(at: destinationURL)
                        }
                        try fm.moveItem(at: temporaryURL, to: destinationURL)
                        globalFileIndex += 1
                    }

                    // atomic rename: .partial → final
                    if fm.fileExists(atPath: finalDir.path) {
                        try fm.removeItem(at: finalDir)
                    }
                    try fm.moveItem(at: partialDir, to: finalDir)
                }

                await MainActor.run {
                    self.installState = .downloaded
                    self.downloadMetrics = nil
                    self.refreshState()
                }
            } catch is CancellationError {
                for asset in LiveModelDefinition.all {
                    try? fm.removeItem(at: LiveModelDefinition.partialDirectory(for: asset))
                }
                await MainActor.run {
                    self.installState = .notInstalled
                    self.downloadMetrics = nil
                    self.refreshState()
                }
            } catch {
                for asset in LiveModelDefinition.all {
                    try? fm.removeItem(at: LiveModelDefinition.partialDirectory(for: asset))
                }
                await MainActor.run {
                    self.downloadMetrics = nil
                    self.installState = .failed(error.localizedDescription)
                }
            }

            await MainActor.run {
                self.currentTask = nil
            }
        }

        currentTask = task
        await task.value
    }

    func cancelDownload() {
        currentTask?.cancel()
    }

    // MARK: - HuggingFace API: List All Files in Repo

    /// 递归列出 repo 中所有文件 (通过 HF /tree API)
    /// 自动排除 excludePatterns 中的文件
    private func listRepoFiles(for asset: LiveModelAsset) async throws -> [String] {
        // 尝试所有 host，直到成功
        var lastError: Error?
        for host in Self.hosts {
            do {
                let files = try await fetchTreeRecursive(host: host, repo: asset.repositoryID, path: "")
                let filtered = files.filter { LiveModelDefinition.shouldDownload($0, for: asset) }
                PCLog.debug("[LiveDL] \(host): \(asset.id) found \(filtered.count) files (excluded \(files.count - filtered.count))")
                return filtered
            } catch {
                lastError = error
                PCLog.debug("[LiveDL] \(host) tree API failed: \(error.localizedDescription)")
            }
        }
        throw lastError ?? DownloadError.invalidResponse
    }

    /// 递归获取目录树中的所有文件路径
    private func fetchTreeRecursive(host: String, repo: String, path: String) async throws -> [String] {
        let urlPath = path.isEmpty
            ? "https://\(host)/api/models/\(repo)/tree/main"
            : "https://\(host)/api/models/\(repo)/tree/main/\(path)"

        guard let url = URL(string: urlPath) else {
            throw DownloadError.invalidURL(urlPath)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.invalidResponse
        }

        var files: [String] = []
        for item in items {
            guard let type = item["type"] as? String,
                  let itemPath = item["path"] as? String else { continue }

            if type == "file" {
                files.append(itemPath)
            } else if type == "directory" {
                let subFiles = try await fetchTreeRecursive(host: host, repo: repo, path: itemPath)
                files.append(contentsOf: subFiles)
            }
        }
        return files
    }

    // MARK: - Download Sources (hf-mirror + huggingface only, NO ModelScope)

    /// LIVE 模型下载源: hf-mirror (国内优先) → huggingface.co
    /// 注意: 与 LLM 的三源策略不同, csukuangfj/ 在 ModelScope 上返回 404, 所以不走 ModelScope。
    /// LLM (E2B/E4B) 的三源下载逻辑在 ModelDownloader.swift 中, 完全不受影响。
    private static func downloadSources(for asset: LiveModelAsset, file: String) -> [DownloadSource] {
        var sources: [DownloadSource] = []
        for host in hosts {
            // 文件路径可能包含子目录，需要对每段编码
            let encodedFile = file.components(separatedBy: "/")
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                .joined(separator: "/")
            let urlString = "https://\(host)/\(asset.repositoryID)/resolve/main/\(encodedFile)"
            if let url = URL(string: urlString) {
                sources.append(.init(label: host, url: url))
            }
        }
        return sources
    }

    // MARK: - Cleanup

    private func cleanupStalePartials() {
        let fm = FileManager.default
        for asset in LiveModelDefinition.all {
            let partial = LiveModelDefinition.partialDirectory(for: asset)
            if fm.fileExists(atPath: partial.path) {
                try? fm.removeItem(at: partial)
            }
        }
    }
}
