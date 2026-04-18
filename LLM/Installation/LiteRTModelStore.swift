import Foundation

// MARK: - LiteRT Model Store
//
// ModelInstaller conformer for .litertlm 单文件模型。
// 下载使用 URLSession，存储到 Documents/models/<fileName>。

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

                    // 下载
                    let (asyncBytes, response) = try await URLSession.shared.bytes(from: model.downloadURL)

                    // HTTP 状态校验 — 防止 404/403 错误页被当作模型文件保存
                    if let httpResponse = response as? HTTPURLResponse,
                       !(200..<300).contains(httpResponse.statusCode) {
                        throw DownloadError.httpStatus(httpResponse.statusCode)
                    }

                    let totalSize = (response as? HTTPURLResponse)
                        .flatMap { $0.expectedContentLength > 0 ? $0.expectedContentLength : nil }
                        ?? model.expectedFileSize

                    let fileHandle = try FileHandle(forWritingTo: {
                        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                        return tempURL
                    }())
                    defer { try? fileHandle.close() }

                    var bytesReceived: Int64 = 0
                    var buffer = Data()
                    let flushInterval: Int64 = 1024 * 1024 // 1 MB

                    for try await byte in asyncBytes {
                        buffer.append(byte)
                        bytesReceived += 1

                        if Int64(buffer.count) >= flushInterval {
                            fileHandle.write(buffer)
                            buffer.removeAll(keepingCapacity: true)

                            await MainActor.run {
                                self.downloadProgress[modelID] = DownloadProgress(
                                    bytesReceived: bytesReceived,
                                    totalBytes: totalSize,
                                    currentFile: model.fileName
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

                    // 文件大小校验 — 捕获截断下载
                    let fileAttrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                    let actualSize = (fileAttrs[.size] as? Int64) ?? 0
                    if model.expectedFileSize > 0, actualSize < model.expectedFileSize / 2 {
                        // 实际大小不到预期的一半 — 明显不完整
                        try? FileManager.default.removeItem(at: tempURL)
                        throw DownloadError.invalidResponse
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
        let path = modelsDirectory.appendingPathComponent(model.fileName)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    func refreshInstallStates() {
        for model in ModelDescriptor.allModels {
            if artifactPath(for: model) != nil {
                installStates[model.id] = .downloaded
            } else {
                installStates[model.id] = .notInstalled
            }
        }
    }
}

// MARK: - Download Error

enum DownloadError: LocalizedError {
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
