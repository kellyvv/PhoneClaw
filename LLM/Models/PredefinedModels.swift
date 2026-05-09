import Foundation

// MARK: - Predefined Models
//
// LiteRT-LM 的 Gemma 4 模型描述符。
// 产品层和 UI 通过 ModelCatalog.availableModels 拿到这些，不直接引用。

public extension ModelDescriptor {

    // MARK: - Gemma 4 E2B (LiteRT)

    /// Gemma 4 E2B — 轻量, ~2.4 GB 单文件，适合 Live 和日常聊天
    static let gemma4E2B = ModelDescriptor(
        id: "gemma-4-e2b-it-litert",
        displayName: "Gemma 4 E2B",
        family: .gemma4,
        artifactKind: .litertlmFile,
        downloadURLs: [
            // 1. ModelScope (国内优先)
            URL(string: "https://modelscope.cn/models/litert-community/gemma-4-E2B-it-litert-lm/resolve/master/gemma-4-E2B-it.litertlm")!,
            // 2. HuggingFace Mirror (hf-mirror.com)
            URL(string: "https://hf-mirror.com/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!,
            // 3. HuggingFace (原站)
            URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!,
        ],
        fileName: "gemma-4-E2B-it.litertlm",
        // expectedFileSize 仅供 UI 进度估算 / 磁盘空间预检,
        // 不参与下载完成的硬校验 (ResumableAssetDownloader v1.3.2+ 只信任
        // HTTP 服务器返回的 Content-Length, 不再用常量做 fallback 校验)。
        // 数值取自 HF 当前实际大小, 上游若重传可能略变, 不影响功能。
        expectedFileSize: 2_588_147_712,
        capabilities: ModelCapabilities(
            supportsVision: true,
            supportsAudio: true,
            supportsLive: true,
            supportsStructuredPlanning: false,
            supportsThinking: true,
            supportsPersistentSession: true,
            supportsSessionSnapshot: false,
            // LiteRT GPU KV-cache = 4096 (vs 32K 省 ~4 GB Metal buffer).
            // safeContextBudgetTokens 是**总预算** (prompt + reservedOutput),
            // 必须 ≤ KV cache (4096) 才能避免 overflow.
            // 2026-04-23: 1300/700 (2048 KV) → 3000/900 (4096 KV). 首轮 Calendar /
            // Contacts / Health 等 skill 触发时 schema 进 prompt, 1300 总预算会
            // hard-reject 所有技能型对话.
            // 2026-04-26: 3000/900 → 3500/700 (跟 E4B 同步). 英文 contacts 这种
            // 厚 schema (3 工具) 会推到 ~2200 prompt, 加 900 output = 3100 偶发
            // 超 3000 旧预算. 改 3500 给英文留余量, output 900 → 700 (大部分
            // tool_call + 简短回复 700 够; 极端长 reply 偶发截断, 但触发率低).
            // KV margin: 4096 - 3500 = 596 (宽松).
            safeContextBudgetTokens: 3500,
            defaultReservedOutputTokens: 700
        ),
        runtimeProfile: MLXModelProfiles.gemma4_e2b
    )

    // MARK: - Gemma 4 E4B (LiteRT)

    /// Gemma 4 E4B — 重量, ~3.4 GB 单文件，支持复杂规划和多工具编排
    static let gemma4E4B = ModelDescriptor(
        id: "gemma-4-e4b-it-litert",
        displayName: "Gemma 4 E4B",
        family: .gemma4,
        artifactKind: .litertlmFile,
        downloadURLs: [
            // 1. ModelScope (国内优先)
            URL(string: "https://modelscope.cn/models/litert-community/gemma-4-E4B-it-litert-lm/resolve/master/gemma-4-E4B-it.litertlm")!,
            // 2. HuggingFace Mirror (hf-mirror.com)
            URL(string: "https://hf-mirror.com/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm")!,
            // 3. HuggingFace (原站)
            URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm")!,
        ],
        fileName: "gemma-4-E4B-it.litertlm",
        // expectedFileSize 仅供 UI 进度估算 / 磁盘空间预检, 不参与硬校验。
        // 见 E2B 同字段注释。
        expectedFileSize: 3_659_530_240,
        capabilities: ModelCapabilities(
            supportsVision: true,
            supportsAudio: true,
            supportsLive: false,          // E4B CPU 延迟太高，不适合 Live
            supportsStructuredPlanning: true,
            supportsThinking: true,
            supportsPersistentSession: true,
            supportsSessionSnapshot: false,
            // safeContextBudgetTokens 是**总预算** (estimatedPromptTokens +
            // reservedOutputTokens), 不是 input 单边. exceedsSafeContextBudget
            // 检查 prompt+output 总和 ≤ 此值, 必须 ≤ KV cache 才能避免 overflow.
            //
            // 2026-04-26: KV cache 2048 → 4096 (LiteRTBackend.swift 同步改),
            // 总预算 1300 → 3500, output 600 → 700 (匹配 E2B 风格).
            // 之前 2048 KV / 1300 总预算下英文 SKILL 触发首轮就 hard-reject
            // (英文 system prompt 比中文长 300 token + contacts 等厚 schema
            // 工具直接推爆). 提到 4096 KV 让英文场景跟中文一样可用; 代价是
            // E4B 总内存上升到 ~4.4 GB, Sideloadly 免费签名 jetsam 阈值下
            // 会炸 — Sideloadly 用户 E4B 本来就推荐换 E2B, 这里接受.
            // KV margin: 4096 - 3500 = 596 (宽松).
            safeContextBudgetTokens: 3500,
            defaultReservedOutputTokens: 700
        ),
        runtimeProfile: MLXModelProfiles.gemma4_e4b
    )

    // MARK: - All Models

    /// 所有可用模型（按推荐顺序）
    static let allModels: [ModelDescriptor] = [.gemma4E2B, .gemma4E4B]

    /// 默认模型
    static let defaultModel: ModelDescriptor = .gemma4E2B
}
