import Foundation
import CoreImage
import AVFoundation

// MARK: - LLM Core Types
//
// 产品层 (AgentEngine, LiveModeEngine, UI) 依赖的全部值类型定义。
// 这个文件不 import 任何推理框架 (MLXLMCommon, LiteRTLMSwift, CLiteRTLM)。
//
// 规则:
//   - 只用 Foundation / CoreImage 标准类型
//   - 所有 struct 都是 Sendable
//   - 上层通过这些类型描述"要什么"，后端决定"怎么做"

// MARK: - Audio Input (替代 MLXLMCommon.UserInput.Audio)

/// Backend-neutral 音频输入。
public struct AudioInput: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channelCount: Int

    public init(samples: [Float], sampleRate: Double, channelCount: Int = 1) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// 编码为 16-bit PCM WAV Data (适配 LiteRT-LM 音频输入)
    /// 使用 AVAudioFile 写标准 WAV，确保格式完全合规。
    public var wavData: Data {
        // 多声道 → mono (安全兜底)
        let mono: [Float]
        if channelCount > 1 {
            let frameCount = samples.count / channelCount
            mono = (0..<frameCount).map { frame in
                var sum: Float = 0
                for ch in 0..<channelCount { sum += samples[frame * channelCount + ch] }
                return sum / Float(channelCount)
            }
        } else {
            mono = samples
        }

        // 用 AVAudioFile 写一个标准 WAV 文件
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pclaw_audio_\(ProcessInfo.processInfo.globallyUniqueString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let outFile = try AVAudioFile(forWriting: tempURL, settings: settings)

            // 用 Float32 格式写入，AVAudioFile 自动转换为 Int16
            let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )!
            let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(mono.count))!
            buffer.frameLength = AVAudioFrameCount(mono.count)
            memcpy(buffer.floatChannelData![0], mono, mono.count * MemoryLayout<Float>.size)

            try outFile.write(from: buffer)
            return try Data(contentsOf: tempURL)
        } catch {
            print("[AudioInput] AVAudioFile WAV write failed: \(error), falling back to manual")
            return manualWavData(mono: mono)
        }
    }

    /// 手动 WAV header 兜底（仅在 AVAudioFile 失败时使用）
    private func manualWavData(mono: [Float]) -> Data {
        let intSampleRate = max(Int(sampleRate.rounded()), 1)
        let pcm16 = mono.map { sample -> Int16 in
            Int16((min(max(sample, -1), 1) * Float(Int16.max)).rounded())
        }
        let bytesPerSample = MemoryLayout<Int16>.size
        let dataSize = pcm16.count * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append("RIFF".data(using: .ascii)!)
        appendLE(UInt32(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(intSampleRate))
        appendLE(UInt32(intSampleRate * bytesPerSample))
        appendLE(UInt16(bytesPerSample))
        appendLE(UInt16(bytesPerSample * 8))
        data.append("data".data(using: .ascii)!)
        appendLE(UInt32(dataSize))
        for s in pcm16 { appendLE(s) }
        return data
    }

    /// 从 AudioCaptureSnapshot 构造 (替代 UserInput.Audio.from(snapshot:))
    static func from(snapshot: AudioCaptureSnapshot) -> AudioInput {
        AudioInput(
            samples: snapshot.pcm,
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount
        )
    }
}

// MARK: - Inference Stats (替代 LLMStats)

/// 推理统计信息，不绑定具体后端。
///
/// `totalChunks` / `chunksPerSec` 统计的是 stream yield 次数，
/// 不一定等于 tokenizer token 数（LiteRT 一次 yield 可能包含多个 token）。
/// 真实 token 级指标见 `[Engine]` 日志行（来自 C benchmark API）。
public struct InferenceStats: Sendable {
    public var loadTimeMs: Double = 0
    public var ttftMs: Double = 0          // time to first token
    public var chunksPerSec: Double = 0    // stream yield throughput
    public var peakMemoryMB: Double = 0
    public var totalChunks: Int = 0        // stream yield count
    public var backend: String = "unknown" // "litert-cpu" / "mlx-gpu"

    public init() {}
}

// MARK: - Model Family

/// 模型家族。同一家族共享 prompt 格式和能力特征。
public enum ModelFamily: String, Sendable, Codable {
    case gemma4
    // 未来: case qwen, miniCPM, ...
}

// MARK: - Artifact Kind

/// 模型资产的存储格式。决定下载/安装/路径逻辑。
public enum ArtifactKind: String, Sendable {
    /// 单个 .litertlm 文件 (LiteRT-LM)
    case litertlmFile
    /// 多文件目录 (MLX: config.json + safetensors + tokenizer + ...)
    case mlxDirectory
}

// MARK: - Model Capabilities

/// 模型的能力声明。产品层用它判断 UI 和路由。
public struct ModelCapabilities: Sendable {
    public let supportsVision: Bool
    public let supportsAudio: Bool
    public let supportsLive: Bool
    public let supportsStructuredPlanning: Bool
    public let supportsThinking: Bool

    public init(
        supportsVision: Bool = false,
        supportsAudio: Bool = false,
        supportsLive: Bool = false,
        supportsStructuredPlanning: Bool = false,
        supportsThinking: Bool = false
    ) {
        self.supportsVision = supportsVision
        self.supportsAudio = supportsAudio
        self.supportsLive = supportsLive
        self.supportsStructuredPlanning = supportsStructuredPlanning
        self.supportsThinking = supportsThinking
    }
}

// MARK: - Model Descriptor (替代 BundledModelOption)

/// Backend-neutral 模型描述符。
///
/// 描述一个可用模型的全部元数据：身份、家族、资产格式、下载地址、能力、运行时策略。
/// 产品层通过 `ModelCatalog` 拿到 descriptor，通过 `capabilities` 做路由决策，
/// 通过 `runtimeProfile` 拿内存预算。
///
/// 不绑定具体推理框架——同一个模型可以同时有 LiteRT 和 MLX 两种 artifact。
public struct ModelDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let family: ModelFamily
    public let artifactKind: ArtifactKind
    /// 按优先级排列的下载镜像 (ModelScope > HF Mirror > HF)
    public let downloadURLs: [URL]
    /// 本地文件名 (单文件) 或目录名 (多文件)
    public let fileName: String
    /// 预期文件大小 (bytes)，用于下载进度
    public let expectedFileSize: Int64
    /// 模型能力
    public let capabilities: ModelCapabilities
    /// 运行时 profile (内存预算、输出上限)
    /// 复用已有的 ModelRuntimeProfile 类型 (backend-neutral)
    public let runtimeProfile: ModelRuntimeProfile

    /// 兼容旧代码: 返回第一个 URL
    public var downloadURL: URL { downloadURLs[0] }

    public static func == (lhs: ModelDescriptor, rhs: ModelDescriptor) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
