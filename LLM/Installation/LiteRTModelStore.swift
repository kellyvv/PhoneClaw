import Foundation

// MARK: - LiteRT Model Store
//
// ModelInstaller conformer for .litertlm 单文件模型。
// 下载存储到 Documents/models/<fileName>。
// 底层使用 ResumableAssetDownloader，partial/manifest 位于 Documents/models/.downloads/<modelID>/。

@Observable
final class LiteRTModelStore: ModelInstaller {

    // MARK: - State

    private(set) var installStates: [String: ModelInstallState] = [:]
    private(set) var downloadProgress: [String: DownloadProgress] = [:]

    private var activeTasks: [String: Task<Void, Error>] = [:]

    @ObservationIgnored
    private var downloaderStorage: ResumableAssetDownloader?

    // MARK: - Paths

    private var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    // MARK: - Init

    init() {
        refreshInstallStates()

        // 监听模型加载失败（文件损坏）→ 立即刷新安装状态
        NotificationCenter.default.addObserver(
            forName: Notification.Name("LiteRTModelCorrupt"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let modelID = notification.userInfo?["modelID"] as? String {
                Task { [weak self] in
                    try? await self?.downloadCoordinator().purge(assetID: modelID)
                }
            }
            self?.refreshInstallStates()
        }
    }

    // MARK: - ModelInstaller

    func install(model: ModelDescriptor) async throws {
        let modelID = model.id

        // 已安装
        if artifactPath(for: model) != nil {
            installStates[modelID] = .downloaded
            return
        }

        if let activeTask = activeTasks[modelID] {
            try await activeTask.value
            return
        }

        installStates[modelID] = .downloading(completedFiles: 0, totalFiles: 1, currentFile: model.fileName)
        downloadProgress[modelID] = DownloadProgress()

        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performInstall(model: model)
        }
        activeTasks[modelID] = task

        do {
            try await task.value
            activeTasks[modelID] = nil
            installStates[modelID] = .downloaded
            downloadProgress[modelID] = nil
        } catch is CancellationError {
            activeTasks[modelID] = nil
            installStates[modelID] = .notInstalled
            downloadProgress[modelID] = nil
            throw CancellationError()
        } catch {
            activeTasks[modelID] = nil
            installStates[modelID] = .failed(userVisibleErrorMessage(for: error))
            downloadProgress[modelID] = nil
            throw error
        }
    }

    private func performInstall(model: ModelDescriptor) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let asset = DownloadAsset(
            id: model.id,
            displayName: model.displayName,
            destinationDirectory: modelsDirectory,
            files: [
                DownloadFile(
                    relativePath: model.fileName,
                    expectedSize: model.expectedFileSize > 0 ? model.expectedFileSize : nil,
                    sources: model.downloadURLs.enumerated().map { index, url in
                        DownloadFile.Source(label: mirrorName(for: url), url: url, priority: index)
                    }
                )
            ]
        )

        _ = try await downloadCoordinator().download(asset: asset)

        guard let path = artifactPath(for: model) else {
            throw LiteRTDownloadError.invalidResponse
        }
        try await validateDownloadedFile(model: model, at: path)
    }

    /// 根据 URL host 返回镜像名称
    private func mirrorName(for url: URL) -> String {
        guard let host = url.host else { return "Unknown" }
        if host.contains("modelscope") { return "ModelScope" }
        if host.contains("hf-mirror") { return "HF Mirror" }
        if host.contains("huggingface") { return "HuggingFace" }
        return host
    }

    private func validateDownloadedFile(model: ModelDescriptor, at url: URL) async throws {
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (fileAttrs[.size] as? Int64) ?? 0
        if model.expectedFileSize > 0, actualSize < model.expectedFileSize * 9 / 10 {
            let expectedMB = model.expectedFileSize / 1_000_000
            let actualMB = actualSize / 1_000_000
            print("[Download] ❌ 文件大小异常: 期望 ~\(expectedMB)MB, 实际 \(actualMB)MB")
            try? FileManager.default.removeItem(at: url)
            try? await downloadCoordinator().purge(assetID: model.id)
            throw LiteRTDownloadError.invalidResponse
        }
    }

    private func downloadCoordinator() -> ResumableAssetDownloader {
        if let downloaderStorage {
            return downloaderStorage
        }
        let downloader = ResumableAssetDownloader(
            manifestStore: DownloadManifestStore(rootDirectory: modelsDirectory),
            observer: LiteRTDownloadObserver(store: self)
        )
        downloaderStorage = downloader
        return downloader
    }

    private func userVisibleErrorMessage(for error: Error) -> String {
        if let failure = error as? DownloadFailure {
            switch failure {
            case .httpStatus(let code):
                return tr("下载失败：HTTP \(code)", "Download failed: HTTP \(code)")
            case .insufficientDiskSpace(let required, let available):
                return tr(
                    "磁盘空间不足：需要 \(formatBytes(required))，可用 \(formatBytes(available))",
                    "Not enough storage: needs \(formatBytes(required)), available \(formatBytes(available))"
                )
            case .validatorMismatch:
                return tr(
                    "下载源校验不一致，请重试。",
                    "Download source validation changed. Please retry."
                )
            case .manifestCorrupt:
                return tr(
                    "下载记录损坏，已重新开始下载。",
                    "Download record was corrupt and has been restarted."
                )
            case .cancelled:
                return tr("下载已取消", "Download cancelled")
            case .invalidURL, .invalidResponse, .fileSystem:
                return tr(
                    "下载失败，请检查网络后重试。",
                    "Download failed. Check your network and retry."
                )
            }
        }
        return error.localizedDescription
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @MainActor
    fileprivate func applyDownloadProgress(_ snapshot: DownloadProgressSnapshot) {
        let currentFile: String?
        if let activeFilePath = snapshot.activeFilePath {
            if let activeSourceLabel = snapshot.activeSourceLabel {
                currentFile = "\(activeFilePath) (\(activeSourceLabel))"
            } else {
                currentFile = activeFilePath
            }
        } else {
            currentFile = nil
        }

        installStates[snapshot.assetID] = .downloading(
            completedFiles: snapshot.completedFileCount,
            totalFiles: snapshot.totalFileCount,
            currentFile: currentFile ?? ""
        )
        downloadProgress[snapshot.assetID] = DownloadProgress(
            bytesReceived: snapshot.downloadedBytes,
            totalBytes: snapshot.totalBytes,
            bytesPerSecond: snapshot.bytesPerSecond,
            currentFile: currentFile
        )
    }

    func remove(model: ModelDescriptor) throws {
        guard let path = artifactPath(for: model) else { return }
        try FileManager.default.removeItem(at: path)
        Task { try? await downloadCoordinator().purge(assetID: model.id) }
        installStates[model.id] = .notInstalled
    }

    func cancelInstall(modelID: String) {
        activeTasks[modelID]?.cancel()
        Task { await downloadCoordinator().pause(assetID: modelID) }
        activeTasks[modelID] = nil
        installStates[modelID] = .notInstalled
        downloadProgress[modelID] = nil
    }

    func installState(for modelID: String) -> ModelInstallState {
        installStates[modelID] ?? .notInstalled
    }

    func artifactPath(for model: ModelDescriptor) -> URL? {
        // 1. 优先检查 app bundle（打包进去的模型）
        let baseName = (model.fileName as NSString).deletingPathExtension
        let ext = (model.fileName as NSString).pathExtension
        if let bundlePath = Bundle.main.url(forResource: baseName, withExtension: ext) {
            return bundlePath
        }
        // 2. fallback 到 Documents/models/（下载的模型）
        let path = modelsDirectory.appendingPathComponent(model.fileName)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    func refreshInstallStates() {
        for model in ModelDescriptor.allModels {
            if let path = artifactPath(for: model) {
                // 校验文件大小 — 不完整的文件自动清理
                if model.expectedFileSize > 0,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                   let size = attrs[.size] as? Int64,
                   size < model.expectedFileSize * 9 / 10 {
                    let expectedMB = model.expectedFileSize / 1_000_000
                    let actualMB = size / 1_000_000
                    print("[ModelStore] ⚠️ \(model.fileName) 文件不完整 (\(actualMB)MB/\(expectedMB)MB)，已自动清理")
                    try? FileManager.default.removeItem(at: path)
                    Task { try? await downloadCoordinator().purge(assetID: model.id) }
                    installStates[model.id] = .notInstalled
                } else {
                    installStates[model.id] = .downloaded
                }
            } else {
                installStates[model.id] = .notInstalled
            }
        }
    }
}

private actor LiteRTDownloadObserver: DownloadObserver {
    weak var store: LiteRTModelStore?

    init(store: LiteRTModelStore) {
        self.store = store
    }

    func onProgress(_ snapshot: DownloadProgressSnapshot) async {
        await store?.applyDownloadProgress(snapshot)
    }

    func onRetry(
        assetID: String,
        filePath: String,
        source: DownloadFile.Source,
        attempt: Int,
        error: DownloadFailure
    ) async {
        print("[Download] ❌ \(source.label) attempt \(attempt) failed for \(filePath): \(error)")
    }

    func onSourceSwitch(
        assetID: String,
        filePath: String,
        from: DownloadFile.Source?,
        to: DownloadFile.Source,
        reason: DownloadFailure?
    ) async {
        let fromLabel = from?.label ?? "none"
        if let reason {
            print("[Download] Switching source for \(filePath): \(fromLabel) → \(to.label), reason=\(reason)")
        } else {
            print("[Download] Switching source for \(filePath): \(fromLabel) → \(to.label)")
        }
    }

    func onFailure(assetID: String, failure: DownloadFailure) async {
        print("[Download] ❌ asset \(assetID) failed: \(failure)")
    }
}

// MARK: - Download Error

enum LiteRTDownloadError: LocalizedError {
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "下载失败：HTTP \(code)"
        case .invalidResponse:
            return "下载的文件不完整或已损坏，请重试。"
        }
    }
}
