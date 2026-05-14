import Foundation

// MARK: - Download types (顶层, 从主类嵌套结构提出)

struct DownloadSource: Sendable {
    let label: String
    let url: URL
}

final class DownloadTaskClient: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadedFileURL: URL?
    private var response: URLResponse?
    private lazy var session: URLSession = {
        URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }()
    private var task: URLSessionDownloadTask?

    init(progressHandler: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.progressHandler = progressHandler
    }

    func start(request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progressHandler(totalBytesWritten, expected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let temporaryFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(location.pathExtension.isEmpty ? "tmp" : location.pathExtension)

            if FileManager.default.fileExists(atPath: temporaryFileURL.path) {
                try FileManager.default.removeItem(at: temporaryFileURL)
            }

            try FileManager.default.moveItem(at: location, to: temporaryFileURL)
            downloadedFileURL = temporaryFileURL
            response = downloadTask.response
        } catch {
            downloadedFileURL = nil
            response = nil
            continuation?.resume(throwing: error)
            continuation = nil
            self.task = nil
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            continuation = nil
            downloadedFileURL = nil
            response = nil
            self.task = nil
            session.finishTasksAndInvalidate()
        }

        if let error {
            continuation?.resume(throwing: error)
            return
        }

        guard let downloadedFileURL, let response else {
            continuation?.resume(throwing: DownloadError.invalidResponse)
            return
        }

        continuation?.resume(returning: (downloadedFileURL, response))
    }
}

// MARK: - MLXLocalLLMService download extension

extension MLXLocalLLMService {

    func cleanupStalePartialDirectories() {
        let fm = FileManager.default
        for model in Self.availableModels {
            let partialDirectory = ModelPaths.partial(for: model)
            if fm.fileExists(atPath: partialDirectory.path) {
                try? fm.removeItem(at: partialDirectory)
            }
        }
    }

    func preferredDownloadSources(for model: BundledModelOption, file: String) -> [DownloadSource] {
        // HF 系路径: "{repoID}/resolve/main/{file}"  — 用于 hf-mirror / huggingface.co
        let hfPath = "\(model.repositoryID)/resolve/main/\(file)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
            .replacingOccurrences(of: "%2F", with: "/")

        // ModelScope 路径: "{repoID}/resolve/master/{file}"  — 结构和 HF 一样, 分支名是 master
        // 这个端点对 LFS 和非 LFS 文件统一处理 (/api/v1/.../repo?FilePath= 的端点 LFS 会 404)
        let msPath = "\(model.repositoryID)/resolve/master/\(file)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
            .replacingOccurrences(of: "%2F", with: "/")

        var sources: [DownloadSource] = []
        // 国内优先: ModelScope 无需 VPN, 已验证 mlx-community/gemma-4-* 在其上完整可下载
        if let msPath, let url = URL(string: "https://modelscope.cn/models/\(msPath)") {
            sources.append(.init(label: "modelscope.cn", url: url))
        }
        if let hfPath, let url = URL(string: "https://hf-mirror.com/\(hfPath)") {
            sources.append(.init(label: "hf-mirror.com", url: url))
        }
        if let hfPath, let url = URL(string: "https://huggingface.co/\(hfPath)") {
            sources.append(.init(label: "huggingface.co", url: url))
        }
        return sources
    }

    func downloadFile(
        with request: URLRequest,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (URL, URLResponse) {
        let client = DownloadTaskClient(progressHandler: progress)
        return try await client.start(request: request)
    }

    public func downloadModel(id: String) async {
        guard let model = Self.availableModels.first(where: { $0.id == id }) else { return }
        if isModelAvailable(model) {
            refreshModelInstallStates()
            return
        }
        if currentDownloadTasks[id] != nil {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let modelsRoot = ModelPaths.documentsRoot()
            let finalDirectory = ModelPaths.downloaded(for: model)
            let partialDirectory = ModelPaths.partial(for: model)

            await MainActor.run {
                self.modelInstallStates[id] = .checkingSource
            }

            do {
                if !fm.fileExists(atPath: modelsRoot.path) {
                    try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: partialDirectory.path) {
                    try fm.removeItem(at: partialDirectory)
                }
                try fm.createDirectory(at: partialDirectory, withIntermediateDirectories: true)

                let totalFiles = model.requiredFiles.count
                for (index, file) in model.requiredFiles.enumerated() {
                    let downloadSources = preferredDownloadSources(for: model, file: file)
                    guard !downloadSources.isEmpty else {
                        throw DownloadError.invalidURL(file)
                    }

                    var downloadedResult: (URL, URLResponse)?
                    var lastError: Error?

                    for source in downloadSources {
                        try Task.checkCancellation()

                        await MainActor.run {
                            self.modelInstallStates[id] = .downloading(
                                completedFiles: index,
                                totalFiles: totalFiles,
                                currentFile: file
                            )
                            self.modelDownloadMetrics[id] = .init(
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
                            let result = try await downloadFile(with: request) { received, expected in
                                let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
                                let bytesPerSecond = Double(received) / elapsed
                                Task { @MainActor [weak self] in
                                    self?.modelDownloadMetrics[id] = .init(
                                        bytesReceived: received,
                                        totalBytes: expected,
                                        bytesPerSecond: bytesPerSecond,
                                        sourceLabel: source.label
                                    )
                                }
                            }
                            // HTTP 状态码检查必须在循环内: URLSessionDownloadTask 对 4xx/5xx
                            // 也会成功调 didFinishDownloadingTo (下载错误页), 如果只在循环外检查,
                            // 某个 source 返回 404 会直接 throw, 永远不会试下一个 source。
                            guard let http = result.1 as? HTTPURLResponse else {
                                lastError = DownloadError.invalidResponse
                                PCLog.debug("[Downloader] \(source.label) \(file): invalid response, trying next source")
                                continue
                            }
                            guard (200...299).contains(http.statusCode) else {
                                lastError = DownloadError.httpStatus(http.statusCode)
                                PCLog.debug("[Downloader] \(source.label) \(file): HTTP \(http.statusCode), trying next source")
                                continue
                            }
                            downloadedResult = result
                            break
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            lastError = error
                            PCLog.debug("[Downloader] \(source.label) \(file): \(error.localizedDescription), trying next source")
                        }
                    }

                    guard let (temporaryURL, _) = downloadedResult else {
                        throw lastError ?? DownloadError.invalidResponse
                    }

                    let destinationURL = partialDirectory.appendingPathComponent(file)
                    let parentDirectory = destinationURL.deletingLastPathComponent()
                    if !fm.fileExists(atPath: parentDirectory.path) {
                        try fm.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
                    }
                    if fm.fileExists(atPath: destinationURL.path) {
                        try fm.removeItem(at: destinationURL)
                    }
                    try fm.moveItem(at: temporaryURL, to: destinationURL)
                }

                if fm.fileExists(atPath: finalDirectory.path) {
                    try fm.removeItem(at: finalDirectory)
                }
                try fm.moveItem(at: partialDirectory, to: finalDirectory)

                await MainActor.run {
                    self.modelInstallStates[id] = .downloaded
                    self.modelDownloadMetrics[id] = nil
                    self.refreshModelInstallStates()
                }
            } catch is CancellationError {
                try? fm.removeItem(at: partialDirectory)
                await MainActor.run {
                    self.modelInstallStates[id] = .notInstalled
                    self.modelDownloadMetrics[id] = nil
                    self.refreshModelInstallStates()
                }
            } catch {
                try? fm.removeItem(at: partialDirectory)
                await MainActor.run {
                    self.modelDownloadMetrics[id] = nil
                    self.modelInstallStates[id] = .failed(error.localizedDescription)
                }
            }

            await MainActor.run {
                self.currentDownloadTasks[id] = nil
            }
        }

        currentDownloadTasks[id] = task
        await task.value
    }

    public func cancelModelDownload(id: String) {
        guard currentDownloadTasks[id] != nil else { return }
        currentDownloadTasks[id]?.cancel()
    }
}
