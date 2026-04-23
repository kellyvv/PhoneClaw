import Foundation

// MARK: - LIVE Model Asset Definitions
//
// ASR (sherpa-onnx-streaming-zipformer-zh) + TTS (vits-zh-hf-keqing) + VAD (Silero) 的元信息。
// 用于手机端按需下载 LIVE 语音模型，与 LLM 下载基础设施并列但独立。
// VAD 也纳入统一下载流程 (hf-mirror → huggingface.co)，不再由 FluidAudio 自行管理。

struct LiveModelAsset: Sendable {
    let id: String
    let displayName: String
    let directoryName: String
    let repositoryID: String
    /// 验证完整性用的关键文件 (不需要列出全部, 只需要核心模型文件)
    let requiredFiles: [String]
    /// 从 repo 中排除的文件模式 (不下载)
    let excludePatterns: [String]
}

enum LiveModelDefinition {

    static let asr = LiveModelAsset(
        id: "live-asr",
        displayName: "语音识别 (ASR)",
        directoryName: "sherpa-asr-zh",
        repositoryID: "csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30",
        requiredFiles: [
            "encoder.int8.onnx",
            "decoder.onnx",
            "joiner.int8.onnx",
            "tokens.txt"
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md",
            "test_wavs/"
        ]
    )

    static let tts = LiveModelAsset(
        id: "live-tts",
        displayName: "语音合成 (TTS)",
        directoryName: "vits-zh-hf-keqing",
        repositoryID: "csukuangfj/vits-zh-hf-keqing",
        requiredFiles: [
            "keqing.onnx",
            "lexicon.txt",
            "tokens.txt",
            "date.fst"        // 验证 FST 类文件也下载完整
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md"
        ]
    )

    static let vad = LiveModelAsset(
        id: "live-vad",
        displayName: "语音检测 (VAD)",
        directoryName: "silero-vad-coreml",
        repositoryID: "FluidInference/silero-vad-coreml",
        requiredFiles: [
            "silero-vad-unified-256ms-v6.0.0.mlmodelc"
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md",
            "config.json",
            "graphs/",
            // Only need the 256ms unified v6, exclude all other variants
            "silero-vad-unified-256ms-v6.0.0.mlpackage/",
            "silero-vad-unified-v6.0.0.mlmodelc/",
            "silero-vad-unified-v6.0.0.mlpackage/",
            "silero_vad.mlmodelc/",
            "silero_vad_se_trained.mlpackage/",
            "silero_vad_se_trained_4bit.mlmodelc/"
        ]
    )

    static let all: [LiveModelAsset] = [asr, tts, vad]

    /// 合并 ID，用于 UI 展示和状态管理
    static let combinedID = "live-voice-models"

    /// 总大小估算 (用于 UI 提示)
    static let estimatedSizeMB = 310  // ASR ~167MB + TTS ~136MB + VAD ~5MB

    // MARK: - Path Helpers

    /// 下载目录: Documents/models/<directoryName>/
    static func downloadedDirectory(for asset: LiveModelAsset) -> URL {
        ModelPaths.documentsRoot().appendingPathComponent(asset.directoryName, isDirectory: true)
    }

    static func partialDirectory(for asset: LiveModelAsset) -> URL {
        ModelPaths.documentsRoot().appendingPathComponent("\(asset.directoryName).partial", isDirectory: true)
    }

    /// Bundle 内模型路径（向后兼容打包方式）
    static func bundledDirectory(for asset: LiveModelAsset) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let dir = resourceURL.appendingPathComponent(asset.directoryName, isDirectory: true)
        guard hasRequiredFiles(asset, at: dir) else { return nil }
        return dir
    }

    /// 解析模型路径: Bundle 优先, 否则 Documents
    static func resolve(for asset: LiveModelAsset) -> URL? {
        if let bundled = bundledDirectory(for: asset) {
            return bundled
        }
        let downloaded = downloadedDirectory(for: asset)
        if hasRequiredFiles(asset, at: downloaded) {
            return downloaded
        }
        return nil
    }

    static func hasRequiredFiles(_ asset: LiveModelAsset, at directory: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return asset.requiredFiles.allSatisfy { file in
            fm.fileExists(atPath: directory.appendingPathComponent(file).path)
        }
    }

    /// 所有 LIVE 模型是否都已就绪 (Bundle 或 Documents)
    static var isAvailable: Bool {
        all.allSatisfy { resolve(for: $0) != nil }
    }

    // MARK: - File Filter

    /// 判断文件是否需要下载 (排除 excludePatterns 中的文件)
    static func shouldDownload(_ path: String, for asset: LiveModelAsset) -> Bool {
        for pattern in asset.excludePatterns {
            if pattern.hasSuffix("/") {
                // 目录排除
                if path.hasPrefix(pattern) || path.hasPrefix(String(pattern.dropLast())) {
                    return false
                }
            } else if path == pattern || path.hasSuffix("/\(pattern)") {
                return false
            }
        }
        return true
    }
}
