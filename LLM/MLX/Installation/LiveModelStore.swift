import Foundation

// MARK: - LIVE Model Store
//
// Orchestrates the three LIVE voice assets on top of ResumableAssetDownloader.
// Intermediate state lives under Documents/models/.downloads/<assetID>/ and is
// finalized into Documents/models/<directoryName>/ only after required files pass.

@Observable
final class LiveModelStore {
    private(set) var installState: ModelInstallState = .notInstalled
    private(set) var downloadMetrics: ModelDownloadMetrics?
    private(set) var resumableAssetCount: Int = 0

    private var currentTask: Task<Void, Never>?
    private var activeTasks: [String: Task<DownloadProgressSnapshot, Error>] = [:]
    private var activePlans: [String: LiveAssetDownloadPlan] = [:]
    private var progressSnapshots: [String: DownloadProgressSnapshot] = [:]

    @ObservationIgnored
    private var manifestStoreStorage: DownloadManifestStore?

    @ObservationIgnored
    private var downloaderStorage: ResumableAssetDownloader?

    var isAvailable: Bool {
        LiveModelDefinition.isAvailable
    }

    var completedAssetCount: Int {
        LiveModelDefinition.all.filter { LiveModelDefinition.resolve(for: $0) != nil }.count
    }

    func refreshState() {
        cleanupLegacyPartialsWithoutManifest()
        if LiveModelDefinition.isAvailable {
            installState = .downloaded
            downloadMetrics = nil
            resumableAssetCount = 0
        } else if case .downloading = installState {
            return
        } else if case .checkingSource = installState {
            return
        } else {
            installState = .notInstalled
            refreshResumableStates()
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
            await self.runDownloadAll()
        }
        currentTask = task
        await task.value
    }

    func cancelDownload() {
        currentTask?.cancel()
        for task in activeTasks.values {
            task.cancel()
        }
    }

    @MainActor
    func removeAll() async throws {
        cancelDownload()
        for asset in LiveModelDefinition.all {
            if let resolved = LiveModelDefinition.resolve(for: asset),
               resolved.path.hasPrefix(ModelPaths.documentsRoot().path) {
                try? FileManager.default.removeItem(at: resolved)
            }
            try? FileManager.default.removeItem(at: LiveModelDefinition.partialDirectory(for: asset))
            try await manifestStore().purge(assetID: asset.id)
        }
        installState = .notInstalled
        downloadMetrics = nil
        resumableAssetCount = 0
    }

    private func runDownloadAll() async {
        do {
            try Task.checkCancellation()
            let fm = FileManager.default
            let modelsRoot = ModelPaths.documentsRoot()
            if !fm.fileExists(atPath: modelsRoot.path) {
                try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            }
            cleanupLegacyPartialsWithoutManifest()

            await MainActor.run {
                self.installState = .checkingSource
                self.downloadMetrics = nil
            }

            let missingAssets = LiveModelDefinition.all.filter {
                LiveModelDefinition.resolve(for: $0) == nil
            }
            guard !missingAssets.isEmpty else {
                await MainActor.run {
                    self.installState = .downloaded
                    self.downloadMetrics = nil
                    self.currentTask = nil
                }
                return
            }

            let plans = try await LiveDownloadPlanner.makePlans(for: missingAssets)
            let seededSnapshots = await initialResumeSnapshots(for: plans)
            await MainActor.run {
                self.configureAggregate(plans, seededSnapshots: seededSnapshots)
            }

            for plan in plans {
                try Task.checkCancellation()
                let store = manifestStore()
                let stagingDirectory = try await store.stagingDirectory(for: plan.liveAsset.id)
                let asset = plan.downloadAsset(
                    destinationDirectory: stagingDirectory,
                    preservesWorkspaceOnCompletion: true
                )

                let task = Task<DownloadProgressSnapshot, Error> { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.downloader().download(asset: asset)
                }
                activeTasks[plan.liveAsset.id] = task
                let snapshot = try await task.value
                activeTasks[plan.liveAsset.id] = nil

                try LiveModelInstallFinalizer.validateRequiredFiles(
                    requiredFiles: plan.liveAsset.requiredFiles,
                    assetID: plan.liveAsset.id,
                    at: stagingDirectory
                )
                try LiveModelInstallFinalizer.finalize(
                    stagingDirectory: stagingDirectory,
                    finalDirectory: LiveModelDefinition.downloadedDirectory(for: plan.liveAsset)
                )
                try await store.purge(assetID: plan.liveAsset.id)

                await MainActor.run {
                    self.applyCompletedSnapshot(snapshot)
                }
            }

            await MainActor.run {
                self.installState = .downloaded
                self.downloadMetrics = nil
                self.currentTask = nil
                self.activePlans = [:]
                self.progressSnapshots = [:]
                self.refreshState()
            }
        } catch is CancellationError {
            await MainActor.run {
                self.installState = .notInstalled
                self.downloadMetrics = nil
                self.currentTask = nil
                self.activeTasks.removeAll()
                self.refreshState()
            }
        } catch {
            await MainActor.run {
                self.downloadMetrics = nil
                self.installState = .failed(self.userVisibleErrorMessage(for: error))
                self.currentTask = nil
                self.activeTasks.removeAll()
            }
        }
    }

    private func configureAggregate(
        _ plans: [LiveAssetDownloadPlan],
        seededSnapshots: [String: DownloadProgressSnapshot]
    ) {
        activePlans = Dictionary(uniqueKeysWithValues: plans.map { ($0.liveAsset.id, $0) })
        progressSnapshots = seededSnapshots
        resumableAssetCount = seededSnapshots.count
        applyAggregateProgress(activeSnapshot: nil)
    }

    @MainActor
    fileprivate func applyDownloadProgress(_ snapshot: DownloadProgressSnapshot) {
        guard currentTask != nil, activeTasks[snapshot.assetID] != nil else { return }

        progressSnapshots[snapshot.assetID] = snapshot
        applyAggregateProgress(activeSnapshot: snapshot)
    }

    private func applyCompletedSnapshot(_ snapshot: DownloadProgressSnapshot) {
        progressSnapshots[snapshot.assetID] = snapshot
        applyAggregateProgress(activeSnapshot: nil)
    }

    private func applyAggregateProgress(activeSnapshot: DownloadProgressSnapshot?) {
        let totalFiles = activePlans.values.reduce(0) { $0 + $1.files.count }
        var completedFiles = 0
        var downloadedBytes: Int64 = 0

        for plan in activePlans.values {
            if let snapshot = progressSnapshots[plan.liveAsset.id] {
                completedFiles += min(snapshot.completedFileCount, snapshot.totalFileCount)
                downloadedBytes += snapshot.downloadedBytes
            }
        }

        let currentFile = activeSnapshot.flatMap { snapshot -> String? in
            guard let plan = activePlans[snapshot.assetID] else { return snapshot.activeFilePath }
            guard let activeFilePath = snapshot.activeFilePath else { return plan.liveAsset.displayName }
            return "\(plan.liveAsset.displayName) / \(activeFilePath)"
        }

        installState = .downloading(
            completedFiles: completedFiles,
            totalFiles: max(totalFiles, 1),
            currentFile: currentFile ?? ""
        )
        downloadMetrics = ModelDownloadMetrics(
            bytesReceived: downloadedBytes,
            totalBytes: aggregateTotalBytes(),
            bytesPerSecond: activeSnapshot?.bytesPerSecond,
            sourceLabel: activeSnapshot?.activeSourceLabel
        )
    }

    private func aggregateTotalBytes() -> Int64? {
        var total: Int64 = 0
        for plan in activePlans.values {
            guard let bytes = plan.totalBytes else { return nil }
            total += bytes
        }
        return total
    }

    private func initialResumeSnapshots(
        for plans: [LiveAssetDownloadPlan]
    ) async -> [String: DownloadProgressSnapshot] {
        var snapshots: [String: DownloadProgressSnapshot] = [:]
        for plan in plans {
            guard let state = try? await manifestStore().resumeState(for: plan.liveAsset.id),
                  state.downloadedBytes > 0 else {
                continue
            }

            snapshots[plan.liveAsset.id] = DownloadProgressSnapshot(
                assetID: plan.liveAsset.id,
                completedFileCount: 0,
                totalFileCount: plan.files.count,
                downloadedBytes: state.downloadedBytes,
                totalBytes: state.totalBytes ?? plan.totalBytes,
                bytesPerSecond: nil,
                activeFilePath: nil,
                activeSourceLabel: nil,
                phase: .paused,
                updatedAt: Date()
            )
        }
        return snapshots
    }

    private func refreshResumableStates() {
        Task { [weak self] in
            guard let self else { return }

            var count = 0
            var downloadedBytes: Int64 = 0
            var totalBytes: Int64 = 0
            var hasUnknownTotal = false

            for asset in LiveModelDefinition.all where LiveModelDefinition.resolve(for: asset) == nil {
                guard let state = try? await self.manifestStore().resumeState(for: asset.id) else {
                    continue
                }
                count += 1
                downloadedBytes += state.downloadedBytes
                if let total = state.totalBytes {
                    totalBytes += total
                } else {
                    hasUnknownTotal = true
                }
            }

            await MainActor.run {
                guard !LiveModelDefinition.isAvailable else {
                    self.resumableAssetCount = 0
                    self.downloadMetrics = nil
                    return
                }

                self.resumableAssetCount = count
                guard case .notInstalled = self.installState else { return }

                if count > 0 {
                    self.downloadMetrics = ModelDownloadMetrics(
                        bytesReceived: downloadedBytes,
                        totalBytes: hasUnknownTotal ? nil : totalBytes,
                        bytesPerSecond: nil,
                        sourceLabel: nil
                    )
                } else {
                    self.downloadMetrics = nil
                }
            }
        }
    }

    private func cleanupLegacyPartialsWithoutManifest() {
        for asset in LiveModelDefinition.all {
            let partial = LiveModelDefinition.partialDirectory(for: asset)
            guard FileManager.default.fileExists(atPath: partial.path) else { continue }
            if !FileManager.default.fileExists(atPath: manifestPath(for: asset.id).path) {
                try? FileManager.default.removeItem(at: partial)
            }
        }
    }

    private func manifestPath(for assetID: String) -> URL {
        ModelPaths.documentsRoot()
            .appendingPathComponent(DownloadManifestStore.workspaceDirectoryName, isDirectory: true)
            .appendingPathComponent(assetID, isDirectory: true)
            .appendingPathComponent(DownloadManifestStore.manifestFileName, isDirectory: false)
    }

    private func userVisibleErrorMessage(for error: Error) -> String {
        if let failure = error as? DownloadFailure {
            switch failure {
            case .httpStatus(let code):
                return tr("LIVE 模型下载失败：HTTP \(code)", "LIVE model download failed: HTTP \(code)")
            case .insufficientDiskSpace(let required, let available):
                return tr(
                    "磁盘空间不足：需要 \(formatBytes(required))，可用 \(formatBytes(available))",
                    "Not enough storage: needs \(formatBytes(required)), available \(formatBytes(available))"
                )
            case .manifestCorrupt:
                return tr("下载记录损坏，已重新开始下载。", "Download record was corrupt and has been restarted.")
            case .cancelled:
                return tr("下载已取消", "Download cancelled")
            case .invalidURL, .invalidResponse, .validatorMismatch, .fileSystem:
                return tr("LIVE 模型下载失败，请检查网络后重试。", "LIVE model download failed. Check your network and retry.")
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

    private func manifestStore() -> DownloadManifestStore {
        if let manifestStoreStorage {
            return manifestStoreStorage
        }
        let store = DownloadManifestStore(rootDirectory: ModelPaths.documentsRoot())
        manifestStoreStorage = store
        return store
    }

    private func downloader() -> ResumableAssetDownloader {
        if let downloaderStorage {
            return downloaderStorage
        }
        let downloader = ResumableAssetDownloader(
            manifestStore: manifestStore(),
            observer: LiveDownloadObserver(store: self)
        )
        downloaderStorage = downloader
        return downloader
    }
}

private actor LiveDownloadObserver: DownloadObserver {
    weak var store: LiveModelStore?

    init(store: LiveModelStore) {
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
        PCLog.debug("[LiveDL] \(source.label) attempt \(attempt) failed for \(assetID)/\(filePath): \(error)")
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
            PCLog.debug("[LiveDL] Switching source for \(assetID)/\(filePath): \(fromLabel) -> \(to.label), reason=\(reason)")
        } else {
            PCLog.debug("[LiveDL] Switching source for \(assetID)/\(filePath): \(fromLabel) -> \(to.label)")
        }
    }

    func onFailure(assetID: String, failure: DownloadFailure) async {
        PCLog.debug("[LiveDL] asset \(assetID) failed: \(failure)")
    }
}
