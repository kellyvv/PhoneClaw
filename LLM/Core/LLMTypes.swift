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

// MARK: - Companion File (兄弟文件, 例如 mmproj / ANE 加速器)

/// 后下载的归档格式 — `LiteRTModelStore.performInstall` 在文件下载完后会按这个
/// 字段做后处理 (例如 `.zip` 走 `ZipExtractor.extract`)。
public enum ArchiveFormat: String, Sendable {
    case zip
}

/// Companion 在模型 bundle 里的角色。backend (例如 MiniCPMVBackend) 的 bundleResolver
/// 按 role 找文件, 而不是按文件名硬编码 — 让 OBS / HF 上不同源的同一模型可以有不同
/// 的下载文件名 (例如 OpenBMB OBS 叫 `mmproj-model-f16.gguf`, 而我们之前的命名约定
/// 是 `MiniCPM-V-4_6-mmproj-f16.gguf`) 而不影响 backend 加载逻辑。
public enum CompanionRole: String, Sendable, Codable {
    /// 多模态投影 — vision tower 输出投到 LLM embedding 空间的中间层。
    /// MiniCPM-V / LLaVA / Qwen-VL 这类 vision-LLM 必需。
    case multimodalProjector
    /// CoreML ANE 加速的 vision tower (mlmodelc 目录, 通常打 .zip 上传)。
    /// 可选 — 缺失时 backend 回退到 CPU/GPU vision 路径。
    case coreMLVisionEncoder
    /// 通用 sidecar — 不归任何上面的类的兄弟文件。
    case other
}

/// "Companion file" = 跟主模型权重并列必须 (或可选) 的兄弟文件。
///
/// 典型使用场景: MiniCPM-V GGUF bundle —
///   - 主文件 (ModelDescriptor.fileName): LLM 主权重 .gguf
///   - companion: mmproj .gguf (vision projector)
///   - companion: CoreML ANE .mlmodelc.zip (需要解压)
///
/// 设计要点:
///   - 每个 companion 自带完整下载元数据 (URLs / 大小 / 归档格式), 不复用主文件的
///   - `extractedDirectoryName` 非 nil 表示这是个归档文件, 下载完要解压成同名目录
///     (不带 .zip 后缀)。例如 `coreml_minicpmv46_vit_all_f32.mlmodelc.zip` 解压
///     成 `coreml_minicpmv46_vit_all_f32.mlmodelc/` 目录。
///   - `isRequired = false` 的 companion (例如 ANE 加速可选, 缺失 fallback 到 CPU)
///     下载失败不阻塞整个 install 流程, 只记一个 warn 日志。
public struct CompanionFile: Sendable {
    /// Companion 在 bundle 里的语义角色. backend 用 role 找文件而不是硬编码文件名。
    public let role: CompanionRole
    /// 落盘文件名 (含扩展名). 例如 "mmproj-model-f16.gguf" 或
    /// "coreml_minicpmv46_vit_all_f32.mlmodelc.zip".
    public let fileName: String
    /// 按优先级排列的下载镜像 (跟主文件用同套镜像策略)
    public let downloadURLs: [URL]
    /// 预期下载字节数 (压缩后, 不是解压后大小). 用于 UI 进度估算。
    public let expectedFileSize: Int64
    /// 归档格式; nil = 直接落盘不需要后处理。
    public let archive: ArchiveFormat?
    /// 归档解压目标目录名 (相对 modelsDirectory). archive 非 nil 时必填,
    /// nil 时忽略。例如 "coreml_minicpmv46_vit_all_f32.mlmodelc".
    public let extractedDirectoryName: String?
    /// false 表示可选: 下载失败/缺失不阻塞 install. 默认 true (必需)。
    /// 典型可选 companion: ANE 加速器 — 缺了 vision encoder fallback 到 CPU。
    public let isRequired: Bool

    /// backend 加载时实际拿到的本地路径名 — 直下载就是 fileName, 归档就是
    /// 解压后的目录名 (extractedDirectoryName)。
    public var localResourceName: String {
        extractedDirectoryName ?? fileName
    }

    public init(
        role: CompanionRole,
        fileName: String,
        downloadURLs: [URL],
        expectedFileSize: Int64,
        archive: ArchiveFormat? = nil,
        extractedDirectoryName: String? = nil,
        isRequired: Bool = true
    ) {
        self.role = role
        self.fileName = fileName
        self.downloadURLs = downloadURLs
        self.expectedFileSize = expectedFileSize
        self.archive = archive
        self.extractedDirectoryName = extractedDirectoryName
        self.isRequired = isRequired
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
    /// 兄弟文件 (mmproj / ANE 加速 / 其它 sidecar)。空数组表示单文件模型。
    /// 多文件 bundle (ArtifactKind.ggufBundle) 用这里声明额外要下的文件。
    public let companionFiles: [CompanionFile]
    /// 模型能力
    public let capabilities: ModelCapabilities
    /// 运行时 profile (内存预算、输出上限)
    /// 复用已有的 ModelRuntimeProfile 类型 (backend-neutral)
    public let runtimeProfile: ModelRuntimeProfile

    /// 兼容旧代码: 返回第一个 URL
    public var downloadURL: URL { downloadURLs[0] }

    /// bundle 总下载体积 (主文件 + 所有 companions 压缩后字节)。用于 UI 进度估算。
    public var totalDownloadSize: Int64 {
        expectedFileSize + companionFiles.reduce(0) { $0 + $1.expectedFileSize }
    }

    /// 显式 memberwise init: 给 companionFiles 默认 `[]` 让所有已有的 Gemma 4
    /// 单文件 descriptor 调用方不用改 (companionFiles 是这次新加的字段)。
    public init(
        id: String,
        displayName: String,
        family: ModelFamily,
        artifactKind: ArtifactKind,
        downloadURLs: [URL],
        fileName: String,
        expectedFileSize: Int64,
        companionFiles: [CompanionFile] = [],
        capabilities: ModelCapabilities,
        runtimeProfile: ModelRuntimeProfile
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.artifactKind = artifactKind
        self.downloadURLs = downloadURLs
        self.fileName = fileName
        self.expectedFileSize = expectedFileSize
        self.companionFiles = companionFiles
        self.capabilities = capabilities
        self.runtimeProfile = runtimeProfile
    }

    public static func == (lhs: ModelDescriptor, rhs: ModelDescriptor) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
