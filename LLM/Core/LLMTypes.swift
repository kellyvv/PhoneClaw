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
    /// 录音文件原始字节 (WAV) — 可直接传给引擎，跳过手动 WAV 编码
    public let rawFileData: Data?

    public init(samples: [Float], sampleRate: Double, channelCount: Int = 1, rawFileData: Data? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.rawFileData = rawFileData
    }

    /// 编码为 16-bit PCM WAV Data (适配 LiteRT-LM 音频输入)
    /// 最小 44-byte RIFF header + raw PCM — miniaudio 兼容。
    public var wavData: Data {
        let intSampleRate = max(Int(sampleRate.rounded()), 1)

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

        // Float → 16-bit PCM
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
        appendLE(UInt16(1))                           // PCM
        appendLE(UInt16(1))                           // mono
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
            channelCount: snapshot.channelCount,
            rawFileData: snapshot.rawFileData
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

// MARK: - Hotfix Prompt Pipeline DTOs

public enum PromptShape: String, Sendable, Codable {
    case lightFull
    case lightDelta
    case agentFull
    case toolFollowup
    case thinking
    case multimodal
    case live
}

public enum SessionGroup: String, Sendable, Codable {
    case text
    case multimodal
    case live
}

public enum SessionResetReason: String, Sendable, Codable {
    case normalContinuation
    case firstTurn
    case systemChanged
    case shapeChanged
    case toolSchemaChanged
    case thinkingToggle
    case retry
    case enterText
    case enterMultimodal
    case enterLive
    case forceFresh
}

public enum ReuseDecision: Sendable, Equatable {
    case reuse
    case reset(SessionResetReason)
}

public struct BudgetDecision: Sendable, Equatable {
    public let estimatedPromptTokens: Int
    public let reservedOutputTokens: Int
    public let historyMessagesIncluded: Int
    public let historyCharsIncluded: Int

    public init(
        estimatedPromptTokens: Int,
        reservedOutputTokens: Int,
        historyMessagesIncluded: Int,
        historyCharsIncluded: Int
    ) {
        self.estimatedPromptTokens = estimatedPromptTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.historyMessagesIncluded = historyMessagesIncluded
        self.historyCharsIncluded = historyCharsIncluded
    }
}

public struct CanonicalToolResult: Sendable, Equatable {
    public let success: Bool
    public let summary: String
    public let detail: String
    public let errorCode: String?

    public init(
        success: Bool,
        summary: String,
        detail: String,
        errorCode: String? = nil
    ) {
        self.success = success
        self.summary = summary
        self.detail = detail
        self.errorCode = errorCode
    }
}

public struct PromptPlan: Sendable, Equatable {
    public let shape: PromptShape
    public let sessionGroup: SessionGroup
    public let prompt: String
    public let budgetDecision: BudgetDecision
    public let reuseDecision: ReuseDecision

    public init(
        shape: PromptShape,
        sessionGroup: SessionGroup,
        prompt: String,
        budgetDecision: BudgetDecision,
        reuseDecision: ReuseDecision
    ) {
        self.shape = shape
        self.sessionGroup = sessionGroup
        self.prompt = prompt
        self.budgetDecision = budgetDecision
        self.reuseDecision = reuseDecision
    }
}

// MARK: - Model Family

/// 模型家族。同一家族共享 prompt 格式和能力特征。
public enum ModelFamily: String, Sendable, Codable {
    case gemma4
    /// MiniCPM-V (OpenBMB), Qwen3.5 backbone + SigLIP2 vision tower。
    case miniCPMV
    // 未来: case qwen, ...
}

// MARK: - Artifact Kind

/// 模型资产的存储格式。决定下载/安装/路径逻辑。
public enum ArtifactKind: String, Sendable {
    /// 单个 .litertlm 文件 (LiteRT-LM)
    case litertlmFile
    /// 多文件目录 (MLX: config.json + safetensors + tokenizer + ...)
    case mlxDirectory
    /// GGUF bundle (MiniCPM-V): LLM .gguf + mmproj .gguf + 可选 ANE .mlmodelc。
    /// `ModelDescriptor.fileName` 指向 LLM 主权重, 其它兄弟文件由 backend
    /// 的 bundleResolver 按命名约定派生 (见 AgentEngine 里实现)。
    case ggufBundle
}

// MARK: - Model Capabilities

/// 模型的能力声明。产品层用它判断 UI 和路由。
public struct ModelCapabilities: Sendable {
    public let supportsVision: Bool
    public let supportsAudio: Bool
    public let supportsLive: Bool
    public let supportsStructuredPlanning: Bool
    public let supportsThinking: Bool
    public let supportsPersistentSession: Bool
    public let supportsSessionSnapshot: Bool
    public let safeContextBudgetTokens: Int
    public let defaultReservedOutputTokens: Int

    public init(
        supportsVision: Bool = false,
        supportsAudio: Bool = false,
        supportsLive: Bool = false,
        supportsStructuredPlanning: Bool = false,
        supportsThinking: Bool = false,
        supportsPersistentSession: Bool = false,
        supportsSessionSnapshot: Bool = false,
        safeContextBudgetTokens: Int = 3200,
        defaultReservedOutputTokens: Int = 1024
    ) {
        self.supportsVision = supportsVision
        self.supportsAudio = supportsAudio
        self.supportsLive = supportsLive
        self.supportsStructuredPlanning = supportsStructuredPlanning
        self.supportsThinking = supportsThinking
        self.supportsPersistentSession = supportsPersistentSession
        self.supportsSessionSnapshot = supportsSessionSnapshot
        self.safeContextBudgetTokens = safeContextBudgetTokens
        self.defaultReservedOutputTokens = defaultReservedOutputTokens
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
