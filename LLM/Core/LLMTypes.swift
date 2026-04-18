import Foundation
import CoreImage

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
    public var wavData: Data {
        let integerSampleRate = max(Int(sampleRate.rounded()), 1)
        let clampedSamples = samples.map { sample -> Int16 in
            let limited = min(max(sample, -1), 1)
            return Int16((limited * Float(Int16.max)).rounded())
        }

        let bytesPerSample = MemoryLayout<Int16>.size
        let dataChunkSize = clampedSamples.count * bytesPerSample
        let riffChunkSize = 36 + dataChunkSize
        let byteRate = integerSampleRate * channelCount * bytesPerSample
        let blockAlign = channelCount * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataChunkSize)

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append("RIFF".data(using: .ascii)!)
        appendLE(UInt32(riffChunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(channelCount))
        appendLE(UInt32(integerSampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(blockAlign))
        appendLE(UInt16(bytesPerSample * 8))
        data.append("data".data(using: .ascii)!)
        appendLE(UInt32(dataChunkSize))
        for sample in clampedSamples { appendLE(sample) }

        return data
    }

    /// 从 AudioCaptureSnapshot 构造 (替代 UserInput.Audio.from(snapshot:))
    public static func from(snapshot: AudioCaptureSnapshot) -> AudioInput {
        AudioInput(
            samples: snapshot.pcm,
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount
        )
    }
}

// MARK: - Inference Stats (替代 LLMStats)

/// 推理统计信息，不绑定具体后端。
public struct InferenceStats: Sendable {
    public var loadTimeMs: Double = 0
    public var ttftMs: Double = 0          // time to first token
    public var tokensPerSec: Double = 0
    public var peakMemoryMB: Double = 0
    public var totalTokens: Int = 0
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
    /// HuggingFace direct download URL
    public let downloadURL: URL
    /// 本地文件名 (单文件) 或目录名 (多文件)
    public let fileName: String
    /// 预期文件大小 (bytes)，用于下载进度
    public let expectedFileSize: Int64
    /// 模型能力
    public let capabilities: ModelCapabilities
    /// 运行时 profile (内存预算、输出上限)
    /// 复用已有的 ModelRuntimeProfile 类型 (backend-neutral)
    public let runtimeProfile: ModelRuntimeProfile

    public static func == (lhs: ModelDescriptor, rhs: ModelDescriptor) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
