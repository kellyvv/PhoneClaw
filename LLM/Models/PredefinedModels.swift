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
        expectedFileSize: 2_600_000_000,
        capabilities: ModelCapabilities(
            supportsVision: true,
            supportsAudio: true,
            supportsLive: true,
            supportsStructuredPlanning: false,
            supportsThinking: true,
            supportsPersistentSession: true,
            supportsSessionSnapshot: false,
            // LiteRT GPU KV-cache = 4096 (vs 32K 省 ~4 GB Metal buffer).
            // input + output 必须 ≤ 4096. 输入预算 3000 + 生成预算 900 = 3900,
            // 留 196 token margin 给 BOS/EOS / 系统控制 token / tool_call tail.
            // 2026-04-23: 预算从 1300/700 (对应 2048 KV) 提到 3000/900 (对应 4096 KV) —
            // 首轮调用 Calendar / Contacts / Health 等技能时 SKILL.md 会 inline
            // 进 prompt (~1000-1500 token), 1300 input 预算会 hard-reject 掉所有
            // 技能触发型对话. 3000 input 能 hold 住 system + 2 个 skill + 首轮 user.
            // 输出预算从 700 → 900: 技能触发后模型常常返回 JSON tool_call + 自然语言
            // 解释, 700 偶尔会在 ```json 块中间截断.
            safeContextBudgetTokens: 3000,
            defaultReservedOutputTokens: 900
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
        expectedFileSize: 3_700_000_000,
        capabilities: ModelCapabilities(
            supportsVision: true,
            supportsAudio: true,
            supportsLive: false,          // E4B CPU 延迟太高，不适合 Live
            supportsStructuredPlanning: true,
            supportsThinking: true,
            supportsPersistentSession: true,
            supportsSessionSnapshot: false,
            // LiteRT GPU KV-cache = 4096 (vs 32K 省 ~4 GB Metal buffer).
            // 输入预算 2800 + 生成预算 1000 = 3800, 留 296 token margin.
            // 2026-04-23: 从 1200/700 (对应 2048 KV) 提到 2800/1000 (对应 4096 KV).
            // E4B 相比 E2B 留更多生成预算 (结构化规划会生成更长 tool_call JSON chain),
            // 相应 input 预算小 200 token 保持总量一致.
            safeContextBudgetTokens: 2800,
            defaultReservedOutputTokens: 1000
        ),
        runtimeProfile: MLXModelProfiles.gemma4_e4b
    )

    // MARK: - All Models

    /// 所有可用模型（按推荐顺序）
    static let allModels: [ModelDescriptor] = [.gemma4E2B, .gemma4E4B]

    /// 默认模型
    static let defaultModel: ModelDescriptor = .gemma4E2B
}
