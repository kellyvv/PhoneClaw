import Foundation

// MARK: - LiteRT Model Store
//
// ModelInstaller conformer for .litertlm 单文件模型。
// 下载存储到 Documents/models/<fileName>。
// 底层使用 ResumableAssetDownloader，partial/manifest 位于 Documents/models/.downloads/<modelID>/。

// `@MainActor`: 4 个状态字典 (installStates / downloadProgress / resumableModelIDs /
// activeTasks) 是 SwiftUI @Observable 状态源, 必须收敛到主线程隔离, 否则会被
// 安装协程 (Task { await install(...) }) 和 UI 重渲撞出 Swift Dictionary 的
// 并发破坏 — 见 TestFlight 1.4.0(27) 崩溃。
// 例外: 纯文件系统查询的 `artifactPath` 及其辅助函数标 `nonisolated`, 让
// LiteRTBackend / MiniCPMVBackend 在 nonisolated async load 路径里能同步调。
@Observable
@MainActor
final class LiteRTModelStore: ModelInstaller {
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

    nonisolated private var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    // MARK: - Init

    init() {
        // 启动期一次性清理已下线的 V4.6 CoreML companion 残留 (~3 GB)。
        // 必须在 refreshInstallStates() 之前跑, 否则 installer 会把残留目录
        // 当成"已安装"算进状态里。详见 cleanupObsoleteCoreMLV46 doc。
        cleanupObsoleteCoreMLV46()
        BackgroundDownloadSession.shared.cancelOrphanedTasks()

        refreshInstallStates()

        // 监听模型加载失败（文件损坏）→ 立即刷新安装状态。
        // queue: .main 保证 closure 在主线程执行, 用 assumeIsolated 把这个动态事实
        // 桥接给 Swift 的静态隔离检查 (class 现在是 @MainActor)。
        NotificationCenter.default.addObserver(
            forName: Notification.Name("LiteRTModelCorrupt"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                if let modelID = notification.userInfo?["modelID"] as? String {
                    Task { [weak self] in
                        try? await self?.downloadCoordinator().purge(assetID: modelID)
                    }
                }
                self?.refreshInstallStates()
            }
        }
    }

    // MARK: - Obsolete File Cleanup

    /// MiniCPM-V 4.6 CoreML/ANE companion 的存量清理。
    ///
    /// 背景:
    ///   2026-05 对齐 OpenBMB main (commit 54a9b024), V4.6 整段 CoreML/ANE 路径
    ///   下线 (OpenBMB 上游 bridge 已移除 coreml_path 字段, PredefinedModels
    ///   已移除 companion 声明, MiniCPMVBackend 始终传空 coremlPath)。但老用户
    ///   磁盘上可能还残留:
    ///     - coreml_minicpmv46_vit_all_f32.mlmodelc.zip      ~1 GB
    ///     - coreml_minicpmv46_vit_all_f32.mlmodelc/         ~2 GB
    ///     - (历史包) coreml_minicpmv46_vit_all_f32.mlpackage
    ///     - (历史包) coreml_minicpmv46_vit_all_f16.mlpackage
    ///   不主动清的话 4 GB 设备用户白占 ~3 GB Documents 空间且自己分不清能不能删。
    ///
    /// 此外, 下载到一半就放弃的用户在 `.downloads/<assetID>/` 下还会有这两类残留:
    ///     - coreml_minicpmv46_vit_all_f32.mlmodelc.zip.part        (URLSession 续传缓存)
    ///     - coreml_minicpmv46_vit_all_f32.mlmodelc.zip.resumeData  (NSURLSessionDownloadTask resume token)
    /// 这些路径规则见 DownloadManifestStore.partialFileURL/resumeDataURL。
    ///
    /// 实现要点 (best-effort, 幂等):
    ///   - 候选文件逐个 best-effort 删除, 单个失败不阻塞其它
    ///   - partial 残留只删 coreml zip 这一个文件级别的 .part / .resumeData,
    ///     **不整体 purge asset workspace** —— 否则会误删主 LLM / mmproj 还
    ///     未完成的断点续传状态, 让用户重新下整个 1.6 GB。
    ///   - 只有"所有候选都不在磁盘"时才 set UserDefaults flag, 失败下次启动重试
    ///   - 完全没有候选时也 set flag (避免每次启动空跑 fileExists)
    ///   - manifest JSON 必须同步重写: DownloadManifestStore.resumeState 取
    ///     max(partialBytes, file.downloadedBytes) 决定断点, 即使 .part 已删,
    ///     manifest 里 downloadedBytes>0 的旧 coreml entry 仍会让 V4.6 被标
    ///     成"可继续下载"。只 filter 掉 coreml 条目, 主 LLM / mmproj 保留。
    private static let coreMLV46CleanupKey = "PhoneClaw.coreMLV46Cleanup.v1"

    /// V4.6 asset ID; 经 sanitizedAssetID 不变 (字符全在允许集), 因此 .downloads 子目录
    /// 名就是它本身。这里 hardcode 而不调 DownloadManifestStore.workspaceDirectory,
    /// 是为了避免 cleanup 跨 actor 边界 (init 同步路径)。
    private static let miniCPMV4_6AssetDirectoryName = "minicpm-v-4_6-q4_k_m"

    /// 已下线的 CoreML zip 文件名, 用于匹配 .part / .resumeData 前缀。
    private static let obsoleteCoreMLZipFileName = "coreml_minicpmv46_vit_all_f32.mlmodelc.zip"

    private func cleanupObsoleteCoreMLV46() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.coreMLV46CleanupKey) else { return }

        let fm = FileManager.default
        var allClear = true

        // 1. 最终落盘文件 / 解压目录
        let finalCandidates = [
            "coreml_minicpmv46_vit_all_f32.mlmodelc.zip",
            "coreml_minicpmv46_vit_all_f32.mlmodelc",
            "coreml_minicpmv46_vit_all_f32.mlpackage",
            "coreml_minicpmv46_vit_all_f16.mlpackage",
        ]
        for name in finalCandidates {
            let url = modelsDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                print("[Migration] removed obsolete V4.6 CoreML artifact: \(name)")
            } catch {
                print("[Migration] failed to remove \(name): \(error.localizedDescription)")
                allClear = false
            }
        }

        // 2. partial 下载残留 (.part / .resumeData) — 只清 coreml zip 这一个
        //    文件相关的, 不动主 LLM / mmproj 的断点。
        let v46WorkspaceURL = modelsDirectory
            .appendingPathComponent(DownloadManifestStore.workspaceDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.miniCPMV4_6AssetDirectoryName, isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(atPath: v46WorkspaceURL.path) {
            let prefix = Self.obsoleteCoreMLZipFileName  // 例: "..mlmodelc.zip"
            // 我们要匹配 "<prefix>.part" / "<prefix>.resumeData", 不包括 prefix 本身
            // (那是已落盘文件, 但它应该已经在 step 1 删过; 不在 modelsDirectory 一级
            // 出现在 workspace 里, 是因为安装时会先在 staging 后挪走 — staging 也清掉)。
            for entry in entries where entry.hasPrefix(prefix) {
                let url = v46WorkspaceURL.appendingPathComponent(entry)
                do {
                    try fm.removeItem(at: url)
                    print("[Migration] removed obsolete V4.6 CoreML download residue: \(entry)")
                } catch {
                    print("[Migration] failed to remove \(entry): \(error.localizedDescription)")
                    allClear = false
                }
            }
        }

        // 3. manifest JSON 重写 — 只移除 coreml zip 条目, 保留主 LLM / mmproj。
        //    必要性: DownloadManifestStore.resumeState 取 max(partialBytes,
        //    file.downloadedBytes) 来判断断点 (见 DownloadManifestStore.swift),
        //    所以即使 .part 已删, 只要 manifest 里这条 entry 的 downloadedBytes>0
        //    还是会被识别成 resumable, UI 上把 V4.6 标成"可继续下载"误导用户。
        //    主 LLM / mmproj 的条目不动, 保它们的断点续传状态。
        let manifestURL = v46WorkspaceURL
            .appendingPathComponent(DownloadManifestStore.manifestFileName, isDirectory: false)
        if fm.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder.downloadManifestDecoder.decode(DownloadManifest.self, from: data)
                let filtered = manifest.files.filter { $0.relativePath != Self.obsoleteCoreMLZipFileName }
                if filtered.count != manifest.files.count {
                    let updated = DownloadManifest(
                        schemaVersion: manifest.schemaVersion,
                        assetID: manifest.assetID,
                        createdAt: manifest.createdAt,
                        updatedAt: Date(),
                        files: filtered
                    )
                    let out = try JSONEncoder.downloadManifestEncoder.encode(updated)
                    try out.write(to: manifestURL, options: [.atomic])
                    print("[Migration] rewrote V4.6 manifest to drop CoreML entry")
                }
            } catch {
                print("[Migration] failed to rewrite V4.6 download manifest: \(error.localizedDescription)")
                allClear = false
            }
        }

        if allClear {
            defaults.set(true, forKey: Self.coreMLV46CleanupKey)
        }
    }

    // MARK: - ModelInstaller

    func install(model: ModelDescriptor) async throws {
        // App Store Review Guidelines 2.5.2 红线: 禁止下载并执行可执行代码。
        // 见 docs/RUNTIME_ARCHITECTURE_PLAN.md §10.3 — Native runtime 升级必须走 App 更新。
        // ModelDescriptor 配错时 (e.g. 把 LiteRT framework 写成下载项) 在这里 fail-fast。
        try Self.assertNoNativeBinaryDownloads(in: model)

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

        installStates[modelID] = .checkingSource
        downloadProgress[modelID] = nil

        let initialProgress = await initialDownloadProgress(for: model)
        installStates[modelID] = .downloading(
            completedFiles: 0,
            totalFiles: 1 + model.companionFiles.count,
            currentFile: model.fileName
        )
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
        try await validateRequiredCompanions(for: model, baseDirectory: path.deletingLastPathComponent())

        // 下载完成后处理: 解压归档型 companion (例如 ANE .mlmodelc.zip).
        // 失败处理:
        //   - isRequired=true companion 解压失败 → 整个 install 报错 (用户能 retry).
        //   - isRequired=false 失败 → 打 warn 日志, 继续 (backend 路径会 fallback).
        // 解压成功后删掉 .zip 释放磁盘 (~1 GB).
        //
        // ⚠️ MainActor 警告: performInstall 现在跑在 MainActor 上 (class @MainActor),
        // 当前 PredefinedModels 全是 archive: nil 所以这个 loop 是空的; 一旦未来
        // 再次引入 archive companion (例如重新启用 CoreML mlmodelc.zip ~1GB),
        // ZipExtractor.extract 是同步阻塞调用, 必须包到 `await Task.detached
        // (priority: .userInitiated) { ... }.value` 里执行, 否则会冻 UI 并触发
        // watchdog (iOS 启动期 ~10s, 运行期 ~20s)。
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
                    PCLog.debug("[LiteRTModelStore] WARN: optional companion \(companion.fileName) extract failed: \(error.localizedDescription) — model will load without it (fallback path may be slower)")
                    // 失败的 .zip 留着不删, 用户下次 retry 可能能成功
                }
            }
        }
    }

    /// 给一组 URLs (companion 用) 打 ranked sources, 复用主文件的镜像排序逻辑。
    private func rankedDownloadSources(for urls: [URL]) async -> [DownloadFile.Source] {
        urls.enumerated().map { index, url in
            DownloadFile.Source(label: mirrorName(for: url), url: url, priority: index)
        }
    }

    private func rankedDownloadSources(for model: ModelDescriptor) async -> [DownloadFile.Source] {
        model.downloadURLs.enumerated().map { index, url in
            DownloadFile.Source(label: mirrorName(for: url), url: url, priority: index)
        }
    }

    private func initialDownloadProgress(for model: ModelDescriptor) async -> DownloadProgress {
        let fallbackTotal = model.totalDownloadSize > 0 ? model.totalDownloadSize : nil
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

    private func validateDownloadedFile(model: ModelDescriptor, at url: URL) async throws {
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (fileAttrs[.size] as? Int64) ?? 0
        if model.expectedFileSize > 0, actualSize < model.expectedFileSize * 9 / 10 {
            let expectedMB = model.expectedFileSize / 1_000_000
            let actualMB = actualSize / 1_000_000
            PCLog.debug("[Download] ❌ 文件大小异常: 期望 ~\(expectedMB)MB, 实际 \(actualMB)MB")
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
        activeTasks[model.id]?.cancel()
        activeTasks[model.id] = nil
        let fileManager = FileManager.default
        let candidateDirectories = Set(
            primaryArtifactCandidates(for: model)
                .filter(isUserModelPath)
                .map { $0.deletingLastPathComponent() }
        )

        for artifact in primaryArtifactCandidates(for: model)
            where isUserModelPath(artifact) && fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }

        for directory in candidateDirectories {
            for companion in model.companionFiles {
                for url in companionStorageCandidates(for: companion, baseDirectory: directory) where fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }

        Task { try? await downloadCoordinator().purge(assetID: model.id) }
        installStates[model.id] = .notInstalled
        resumableModelIDs.remove(model.id)
        downloadProgress[model.id] = nil
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

    func hasLocalArtifacts(for model: ModelDescriptor) -> Bool {
        if resumableModelIDs.contains(model.id) || downloadProgress[model.id] != nil {
            return true
        }

        let fileManager = FileManager.default
        let userArtifactCandidates = primaryArtifactCandidates(for: model).filter(isUserModelPath)
        if userArtifactCandidates.contains(where: { fileManager.fileExists(atPath: $0.path) }) {
            return true
        }

        let candidateDirectories = Set(userArtifactCandidates.map { $0.deletingLastPathComponent() })
        for directory in candidateDirectories {
            for companion in model.companionFiles {
                if companionStorageCandidates(for: companion, baseDirectory: directory)
                    .contains(where: { fileManager.fileExists(atPath: $0.path) }) {
                    return true
                }
            }
        }

        return false
    }

    nonisolated func artifactPath(for model: ModelDescriptor) -> URL? {
        for candidate in primaryArtifactCandidates(for: model) {
            guard completeFileExists(at: candidate, expectedSize: model.expectedFileSize) else {
                continue
            }

            let baseDirectory = candidate.deletingLastPathComponent()
            guard requiredCompanionsAvailable(for: model, baseDirectory: baseDirectory) else {
                continue
            }

            return candidate
        }

        return nil
    }

    nonisolated private func primaryArtifactCandidates(for model: ModelDescriptor) -> [URL] {
        var candidates: [URL] = []

        // 1. 优先检查 app bundle（打包进去的模型）
        let baseName = (model.fileName as NSString).deletingPathExtension
        let ext = (model.fileName as NSString).pathExtension
        if let bundlePath = Bundle.main.url(forResource: baseName, withExtension: ext) {
            candidates.append(bundlePath)
        }
        // 2. fallback 到 Documents/models/（下载的模型）
        candidates.append(modelsDirectory.appendingPathComponent(model.fileName))
        return candidates
    }

    nonisolated private func completeFileExists(at url: URL, expectedSize: Int64) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            return true
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return false
        }
        guard expectedSize > 0 else {
            return true
        }
        return size >= expectedSize * 9 / 10
    }

    nonisolated private func requiredCompanionsAvailable(for model: ModelDescriptor, baseDirectory: URL) -> Bool {
        model.companionFiles
            .filter(\.isRequired)
            .allSatisfy { companion in
                companionStorageCandidates(for: companion, baseDirectory: baseDirectory)
                    .contains { completeFileExists(at: $0, expectedSize: companion.expectedFileSize) }
            }
    }

    nonisolated private func companionStorageCandidates(for companion: CompanionFile, baseDirectory: URL) -> [URL] {
        var candidates: [URL] = []

        candidates.append(baseDirectory.appendingPathComponent(companion.localResourceName))
        if companion.fileName != companion.localResourceName {
            candidates.append(baseDirectory.appendingPathComponent(companion.fileName))
        }
        if companion.role == .multimodalProjector {
            candidates.append(baseDirectory.appendingPathComponent("MiniCPM-V-4_6-mmproj-f16.gguf"))
        }

        return Array(Set(candidates))
    }

    private func validateRequiredCompanions(for model: ModelDescriptor, baseDirectory: URL) async throws {
        for companion in model.companionFiles where companion.isRequired {
            let available = companionStorageCandidates(for: companion, baseDirectory: baseDirectory)
                .contains { completeFileExists(at: $0, expectedSize: companion.expectedFileSize) }
            guard available else {
                try? await downloadCoordinator().purge(assetID: model.id)
                throw LiteRTDownloadError.invalidResponse
            }
        }
    }

    func refreshInstallStates() {
        for model in ModelDescriptor.allModels {
            if activeTasks[model.id] != nil {
                continue
            }
            if case .checkingSource = installStates[model.id] {
                continue
            }
            if case .downloading = installStates[model.id] {
                continue
            }

            if let path = artifactPath(for: model) {
                installStates[model.id] = path.path.hasPrefix(Bundle.main.bundlePath) ? .bundled : .downloaded
                resumableModelIDs.remove(model.id)
                downloadProgress[model.id] = nil
            } else {
                purgeIncompletePrimaryArtifactIfNeeded(for: model)
                installStates[model.id] = .notInstalled
            }
        }
        refreshResumableStates()
    }

    private func purgeIncompletePrimaryArtifactIfNeeded(for model: ModelDescriptor) {
        guard model.expectedFileSize > 0 else { return }

        for artifact in primaryArtifactCandidates(for: model)
            where isUserModelPath(artifact) && FileManager.default.fileExists(atPath: artifact.path) {
            guard !completeFileExists(at: artifact, expectedSize: model.expectedFileSize),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: artifact.path),
                  let size = attrs[.size] as? Int64 else {
                continue
            }

            let expectedMB = model.expectedFileSize / 1_000_000
            let actualMB = size / 1_000_000
            PCLog.debug("[ModelStore] ⚠️ \(model.fileName) 文件不完整 (\(actualMB)MB/\(expectedMB)MB)，已自动清理")
            try? FileManager.default.removeItem(at: artifact)
            Task { try? await downloadCoordinator().purge(assetID: model.id) }
        }
    }

    nonisolated private func isUserModelPath(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(modelsDirectory.standardizedFileURL.path)
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
            applyResumableState(nil, for: model)
            return
        }

        let state = try? await downloadManifestStore().resumeState(for: model.id)
        applyResumableState(state, for: model)
    }

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

    // MARK: - App Store 合规防御

    /// 禁止下载的文件后缀 — 任何 Mach-O / 动态库 / framework 都不能走下载链路。
    /// 这些必须随 App 二进制 ship,见 App Store Review Guidelines 2.5.2。
    private static let forbiddenDownloadExtensions: [String] = [
        ".framework", ".xcframework", ".dylib", ".so", ".a", ".bundle"
    ]

    /// 检查 ModelDescriptor 及其 companion files,确保没有 native binary。
    /// 配错就抛 fatalError — 这是架构约束,运行时拒绝绕过。
    static func assertNoNativeBinaryDownloads(in model: ModelDescriptor) throws {
        let allFileNames = [model.fileName] + model.companionFiles.map(\.fileName)
        for fileName in allFileNames {
            let lowered = fileName.lowercased()
            for ext in forbiddenDownloadExtensions where lowered.hasSuffix(ext) {
                let detail = "ModelDescriptor[\(model.id)] declares download of native binary '\(fileName)'. " +
                             "Native runtime (frameworks/dylibs) must ship with the App, not be downloaded. " +
                             "See App Store Review Guidelines 2.5.2 / RUNTIME_ARCHITECTURE_PLAN.md §10.3."
                assertionFailure(detail)
                throw InstallerError.forbiddenNativeBinaryDownload(detail)
            }
        }
    }
}

/// Installer-level structured errors.
enum InstallerError: LocalizedError {
    case forbiddenNativeBinaryDownload(String)

    var errorDescription: String? {
        switch self {
        case .forbiddenNativeBinaryDownload(let detail):
            return detail
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
        PCLog.debug("[Download] ❌ \(source.label) attempt \(attempt) failed for \(filePath): \(error)")
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
            PCLog.debug("[Download] Switching source for \(filePath): \(fromLabel) → \(to.label), reason=\(reason)")
        } else {
            PCLog.debug("[Download] Switching source for \(filePath): \(fromLabel) → \(to.label)")
        }
    }

    func onFailure(assetID: String, failure: DownloadFailure) async {
        PCLog.debug("[Download] ❌ asset \(assetID) failed: \(failure)")
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
