import Foundation

// MARK: - LiteRT Model Store
//
// ModelInstaller conformer for .litertlm 单文件模型。
// 下载存储到 Documents/models/<fileName>。
// 底层使用 ResumableAssetDownloader，partial/manifest 位于 Documents/models/.downloads/<modelID>/。

@Observable
final class LiteRTModelStore: ModelInstaller {
    private static let sourceProbeByteLimit = 128 * 1024
    private static let sourceProbeTimeout: TimeInterval = 6

    // MARK: - State

    private(set) var installStates: [String: ModelInstallState] = [:]
    private(set) var downloadProgress: [String: DownloadProgress] = [:]
    private(set) var resumableModelIDs: Set<String> = []

    private var activeTasks: [String: Task<Void, Error>] = [:]

    @ObservationIgnored
    private var downloaderStorage: ResumableAssetDownloader?
    @ObservationIgnored
    private var manifestStoreStorage: DownloadManifestStore?

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
            resumableModelIDs.remove(modelID)
            downloadProgress[modelID] = nil
            return
        }

        if let activeTask = activeTasks[modelID] {
            try await activeTask.value
            return
        }

        let initialProgress = await initialDownloadProgress(for: model)
        installStates[modelID] = .downloading(completedFiles: 0, totalFiles: 1, currentFile: model.fileName)
        downloadProgress[modelID] = initialProgress

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
            resumableModelIDs.remove(modelID)
        } catch is CancellationError {
            activeTasks[modelID] = nil
            installStates[modelID] = .notInstalled
            if downloadProgress[modelID] != nil {
                resumableModelIDs.insert(modelID)
            }
            await refreshResumableState(for: model)
            throw CancellationError()
        } catch {
            activeTasks[modelID] = nil
            installStates[modelID] = .failed(userVisibleErrorMessage(for: error))
            downloadProgress[modelID] = nil
            await refreshResumableState(for: model)
            throw error
        }
    }

    private func performInstall(model: ModelDescriptor) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let sources = await rankedDownloadSources(for: model)

        // 主文件 (LLM 主权重) — 永远在 files[0]
        var files: [DownloadFile] = [
            DownloadFile(
                relativePath: model.fileName,
                expectedSize: model.expectedFileSize > 0 ? model.expectedFileSize : nil,
                sources: sources
            )
        ]

        // Companion files — GGUF bundle 类模型 (MiniCPM-V) 的 mmproj / ANE 等。
        // 每个 companion 自带 downloadURLs, 我们按主文件相同的镜像排序策略给它
        // 各自打 ranked sources, 一起塞进同一个 DownloadAsset.files 让下载器
        // 一次性串行下完 (manifest 记录每文件的进度 + 断点续传).
        for companion in model.companionFiles {
            let companionSources = await rankedDownloadSources(for: companion.downloadURLs)
            files.append(DownloadFile(
                relativePath: companion.fileName,
                expectedSize: companion.expectedFileSize > 0 ? companion.expectedFileSize : nil,
                sources: companionSources
            ))
        }

        let asset = DownloadAsset(
            id: model.id,
            displayName: model.displayName,
            destinationDirectory: modelsDirectory,
            files: files
        )

        _ = try await downloadCoordinator().download(asset: asset)

        guard let path = artifactPath(for: model) else {
            throw LiteRTDownloadError.invalidResponse
        }
        try await validateDownloadedFile(model: model, at: path)

        // 下载完成后处理: 解压归档型 companion (例如 ANE .mlmodelc.zip).
        // 失败处理:
        //   - isRequired=true companion 解压失败 → 整个 install 报错 (用户能 retry).
        //   - isRequired=false 失败 → 打 warn 日志, 继续 (backend 路径会 fallback).
        // 解压成功后删掉 .zip 释放磁盘 (~1 GB).
        for companion in model.companionFiles {
            guard let archive = companion.archive,
                  let extractedName = companion.extractedDirectoryName else {
                continue  // 直下载, 无后处理
            }
            let archiveURL = modelsDirectory.appendingPathComponent(companion.fileName)
            let extractedURL = modelsDirectory.appendingPathComponent(extractedName)

            // 已存在解压目录 (例如这次 install 是 retry, 上次解压成功了) → 跳过
            if FileManager.default.fileExists(atPath: extractedURL.path) {
                // 清理 .zip 如果还在 (上次解压完没清掉)
                try? FileManager.default.removeItem(at: archiveURL)
                continue
            }

            do {
                switch archive {
                case .zip:
                    try ZipExtractor.extract(at: archiveURL, to: modelsDirectory)
                }
                // 解压验证: 期望的目录应该出现了
                guard FileManager.default.fileExists(atPath: extractedURL.path) else {
                    throw ZipExtractorError.extractionFailed("expected directory \(extractedName) not produced")
                }
                // 释放磁盘
                try? FileManager.default.removeItem(at: archiveURL)
            } catch {
                if companion.isRequired {
                    throw error
                } else {
                    print("[LiteRTModelStore] WARN: optional companion \(companion.fileName) extract failed: \(error.localizedDescription) — model will load without it (fallback path may be slower)")
                    // 失败的 .zip 留着不删, 用户下次 retry 可能能成功
                }
            }
        }
    }

    /// 给一组 URLs (companion 用) 打 ranked sources, 复用主文件的镜像排序逻辑。
    private func rankedDownloadSources(for urls: [URL]) async -> [DownloadFile.Source] {
        let original = urls.enumerated().map { index, url in
            DownloadFile.Source(label: mirrorName(for: url), url: url, priority: index)
        }
        let probeCandidates = original.filter { !isHuggingFaceOrigin($0.url) }
        guard probeCandidates.count > 1 else { return original }

        var results: [SourceProbeResult] = []
        await withTaskGroup(of: SourceProbeResult?.self) { group in
            for source in probeCandidates {
                group.addTask {
                    await Self.probe(source: source)
                }
            }
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
        }

        guard !results.isEmpty else { return original }

        let rankedLabels = results
            .sorted {
                if $0.bytesPerSecond == $1.bytesPerSecond {
                    return $0.source.priority < $1.source.priority
                }
                return $0.bytesPerSecond > $1.bytesPerSecond
            }
            .map(\.source.label)

        let ranked = rankedLabels.compactMap { label in
            original.first { $0.label == label }
        }
        let remaining = original.filter { source in
            !rankedLabels.contains(source.label)
        }
        return (ranked + remaining).enumerated().map { index, source in
            DownloadFile.Source(label: source.label, url: source.url, priority: index)
        }
    }

    private func rankedDownloadSources(for model: ModelDescriptor) async -> [DownloadFile.Source] {
        let original = model.downloadURLs.enumerated().map { index, url in
            DownloadFile.Source(label: mirrorName(for: url), url: url, priority: index)
        }
        let probeCandidates = original.filter { !isHuggingFaceOrigin($0.url) }
        guard probeCandidates.count > 1 else { return original }

        var results: [SourceProbeResult] = []
        await withTaskGroup(of: SourceProbeResult?.self) { group in
            for source in probeCandidates {
                group.addTask {
                    await Self.probe(source: source)
                }
            }
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
        }

        guard !results.isEmpty else { return original }

        let rankedLabels = results
            .sorted {
                if $0.bytesPerSecond == $1.bytesPerSecond {
                    return $0.source.priority < $1.source.priority
                }
                return $0.bytesPerSecond > $1.bytesPerSecond
            }
            .map(\.source.label)

        let ranked = rankedLabels.compactMap { label in
            original.first { $0.label == label }
        }
        let remaining = original.filter { source in
            !rankedLabels.contains(source.label)
        }
        return (ranked + remaining).enumerated().map { index, source in
            DownloadFile.Source(label: source.label, url: source.url, priority: index)
        }
    }

    private static func probe(source: DownloadFile.Source) async -> SourceProbeResult? {
        var request = URLRequest(url: source.url)
        request.setValue("bytes=0-\(sourceProbeByteLimit - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = sourceProbeTimeout

        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            var received = 0
            for try await _ in bytes {
                received += 1
                if received >= sourceProbeByteLimit {
                    break
                }
            }

            guard received > 0 else { return nil }
            let elapsed = max(CFAbsoluteTimeGetCurrent() - startedAt, 0.001)
            return SourceProbeResult(
                source: source,
                bytesPerSecond: Double(received) / elapsed
            )
        } catch {
            return nil
        }
    }

    private func initialDownloadProgress(for model: ModelDescriptor) async -> DownloadProgress {
        let fallbackTotal = model.expectedFileSize > 0 ? model.expectedFileSize : nil
        guard let state = try? await downloadManifestStore().resumeState(for: model.id),
              state.downloadedBytes > 0 else {
            return DownloadProgress(totalBytes: fallbackTotal, currentFile: model.fileName)
        }

        resumableModelIDs.insert(model.id)
        return DownloadProgress(
            bytesReceived: state.downloadedBytes,
            totalBytes: state.totalBytes ?? fallbackTotal,
            bytesPerSecond: nil,
            currentFile: model.fileName
        )
    }

    /// 根据 URL host 返回镜像名称
    private func mirrorName(for url: URL) -> String {
        guard let host = url.host else { return "Unknown" }
        if host.contains("modelscope") { return "ModelScope" }
        if host.contains("hf-mirror") { return "HF Mirror" }
        if host.contains("huggingface") { return "HuggingFace" }
        return host
    }

    private func isHuggingFaceOrigin(_ url: URL) -> Bool {
        url.host?.contains("huggingface.co") == true
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
            manifestStore: downloadManifestStore(),
            observer: LiteRTDownloadObserver(store: self)
        )
        downloaderStorage = downloader
        return downloader
    }

    private func downloadManifestStore() -> DownloadManifestStore {
        if let manifestStoreStorage {
            return manifestStoreStorage
        }
        let store = DownloadManifestStore(rootDirectory: modelsDirectory)
        manifestStoreStorage = store
        return store
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
        guard activeTasks[snapshot.assetID] != nil else { return }

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
        if downloadProgress[modelID] != nil {
            resumableModelIDs.insert(modelID)
        }
        installStates[modelID] = .notInstalled
        refreshResumableStates()
    }

    func installState(for modelID: String) -> ModelInstallState {
        installStates[modelID] ?? .notInstalled
    }

    func hasResumableDownload(for modelID: String) -> Bool {
        resumableModelIDs.contains(modelID)
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
                    resumableModelIDs.remove(model.id)
                    downloadProgress[model.id] = nil
                }
            } else {
                installStates[model.id] = .notInstalled
            }
        }
        refreshResumableStates()
    }

    private func refreshResumableStates() {
        Task { [weak self] in
            guard let self else { return }
            for model in ModelDescriptor.allModels {
                await self.refreshResumableState(for: model)
            }
        }
    }

    private func refreshResumableState(for model: ModelDescriptor) async {
        guard artifactPath(for: model) == nil else {
            await applyResumableState(nil, for: model)
            return
        }

        let state = try? await downloadManifestStore().resumeState(for: model.id)
        await applyResumableState(state, for: model)
    }

    @MainActor
    private func applyResumableState(_ state: DownloadResumeState?, for model: ModelDescriptor) {
        guard let state else {
            resumableModelIDs.remove(model.id)
            if installState(for: model.id) == .notInstalled {
                downloadProgress[model.id] = nil
            }
            return
        }

        resumableModelIDs.insert(model.id)
        guard installState(for: model.id) == .notInstalled else { return }

        downloadProgress[model.id] = DownloadProgress(
            bytesReceived: state.downloadedBytes,
            totalBytes: state.totalBytes ?? (model.expectedFileSize > 0 ? model.expectedFileSize : nil),
            bytesPerSecond: nil,
            currentFile: model.fileName
        )
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

private struct SourceProbeResult: Sendable {
    let source: DownloadFile.Source
    let bytesPerSecond: Double
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
