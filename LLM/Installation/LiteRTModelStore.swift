import Foundation

// MARK: - LiteRT Model Store
//
// ModelInstaller conformer for .litertlm 单文件模型。
// 下载使用 URLSession，存储到 Documents/models/<fileName>。
// 支持多镜像源自动 fallback + 实时速度计算。

@Observable
final class LiteRTModelStore: ModelInstaller {

    // MARK: - State

    private(set) var installStates: [String: ModelInstallState] = [:]
    private(set) var downloadProgress: [String: DownloadProgress] = [:]

    private var activeTasks: [String: Task<Void, Never>] = [:]

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
        ) { [weak self] _ in
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

        installStates[modelID] = .downloading(completedFiles: 0, totalFiles: 1, currentFile: model.fileName)
        downloadProgress[modelID] = DownloadProgress()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    // 确保目录存在
                    try FileManager.default.createDirectory(
                        at: self.modelsDirectory,
                        withIntermediateDirectories: true
                    )

                    let destURL = self.modelsDirectory.appendingPathComponent(model.fileName)
                    let tempURL = destURL.appendingPathExtension("partial")

                    // 清理旧的部分下载
                    try? FileManager.default.removeItem(at: tempURL)

                    // 多镜像源 fallback 下载
                    try await self.downloadWithFallback(
                        urls: model.downloadURLs,
                        tempURL: tempURL,
                        modelID: modelID,
                        expectedFileSize: model.expectedFileSize,
                        fileName: model.fileName
                    )

                    // 文件大小校验 — 实际大小必须 >= 预期的 90%
                    let fileAttrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                    let actualSize = (fileAttrs[.size] as? Int64) ?? 0
                    if model.expectedFileSize > 0, actualSize < model.expectedFileSize * 9 / 10 {
                        let expectedMB = model.expectedFileSize / 1_000_000
                        let actualMB = actualSize / 1_000_000
                        print("[Download] ❌ 文件大小异常: 期望 ~\(expectedMB)MB, 实际 \(actualMB)MB")
                        try? FileManager.default.removeItem(at: tempURL)
                        throw LiteRTDownloadError.invalidResponse
                    }

                    // 移动到最终位置
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: tempURL, to: destURL)

                    await MainActor.run {
                        self.installStates[modelID] = .downloaded
                        self.downloadProgress[modelID] = nil
                    }

                    continuation.resume()
                } catch {
                    if Task.isCancelled {
                        await MainActor.run {
                            self.installStates[modelID] = .notInstalled
                            self.downloadProgress[modelID] = nil
                        }
                        continuation.resume(throwing: CancellationError())
                    } else {
                        await MainActor.run {
                            self.installStates[modelID] = .failed(error.localizedDescription)
                            self.downloadProgress[modelID] = nil
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }

            activeTasks[modelID] = task
        }
    }

    // MARK: - Multi-source Fallback Download

    /// 依次尝试多个镜像源, 第一个成功即停止. 每个源 HTTP 错误或超时则自动 fallback.
    private func downloadWithFallback(
        urls: [URL],
        tempURL: URL,
        modelID: String,
        expectedFileSize: Int64,
        fileName: String
    ) async throws {
        var lastError: Error?

        for (index, url) in urls.enumerated() {
            let sourceName = mirrorName(for: url)
            print("[Download] 尝试镜像 \(index + 1)/\(urls.count): \(sourceName)")

            do {
                try await downloadFromURL(
                    url: url,
                    tempURL: tempURL,
                    modelID: modelID,
                    expectedFileSize: expectedFileSize,
                    fileName: fileName,
                    sourceName: sourceName
                )
                print("[Download] ✅ 从 \(sourceName) 下载成功")
                return // 成功
            } catch is CancellationError {
                throw CancellationError() // 用户取消, 不 fallback
            } catch {
                lastError = error
                print("[Download] ❌ \(sourceName) 失败: \(error.localizedDescription)")
                // 清理失败的部分文件
                try? FileManager.default.removeItem(at: tempURL)
                continue // 尝试下一个
            }
        }

        throw lastError ?? LiteRTDownloadError.invalidResponse
    }

    /// 从单个 URL 下载, 带实时速度计算
    private func downloadFromURL(
        url: URL,
        tempURL: URL,
        modelID: String,
        expectedFileSize: Int64,
        fileName: String,
        sourceName: String
    ) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        // HTTP 状态校验
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw LiteRTDownloadError.httpStatus(httpResponse.statusCode)
        }

        let totalSize = (response as? HTTPURLResponse)
            .flatMap { $0.expectedContentLength > 0 ? $0.expectedContentLength : nil }
            ?? expectedFileSize

        let fileHandle = try FileHandle(forWritingTo: {
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            return tempURL
        }())
        defer { try? fileHandle.close() }

        var bytesReceived: Int64 = 0
        var buffer = Data()
        let flushInterval: Int64 = 1024 * 1024 // 1 MB

        // 速度计算
        let downloadStart = CFAbsoluteTimeGetCurrent()
        var lastSpeedUpdate = downloadStart
        var lastSpeedBytes: Int64 = 0
        var smoothedSpeed: Double = 0

        for try await byte in asyncBytes {
            buffer.append(byte)
            bytesReceived += 1

            if Int64(buffer.count) >= flushInterval {
                fileHandle.write(buffer)
                buffer.removeAll(keepingCapacity: true)

                // 计算实时速度 (滑动平均)
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastSpeedUpdate
                if elapsed > 0.5 {
                    let instantSpeed = Double(bytesReceived - lastSpeedBytes) / elapsed
                    smoothedSpeed = smoothedSpeed > 0
                        ? smoothedSpeed * 0.7 + instantSpeed * 0.3  // EMA 平滑
                        : instantSpeed
                    lastSpeedUpdate = now
                    lastSpeedBytes = bytesReceived
                }

                await MainActor.run {
                    self.downloadProgress[modelID] = DownloadProgress(
                        bytesReceived: bytesReceived,
                        totalBytes: totalSize,
                        bytesPerSecond: smoothedSpeed > 0 ? smoothedSpeed : nil,
                        currentFile: "\(fileName) (\(sourceName))"
                    )
                }
            }

            if Task.isCancelled { throw CancellationError() }
        }

        // 写入剩余
        if !buffer.isEmpty {
            fileHandle.write(buffer)
        }
        try fileHandle.close()
    }

    /// 根据 URL host 返回镜像名称
    private func mirrorName(for url: URL) -> String {
        guard let host = url.host else { return "Unknown" }
        if host.contains("modelscope") { return "ModelScope" }
        if host.contains("hf-mirror") { return "HF Mirror" }
        if host.contains("huggingface") { return "HuggingFace" }
        return host
    }

    func remove(model: ModelDescriptor) throws {
        guard let path = artifactPath(for: model) else { return }
        try FileManager.default.removeItem(at: path)
        installStates[model.id] = .notInstalled
    }

    func cancelInstall(modelID: String) {
        activeTasks[modelID]?.cancel()
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
