import Foundation

// MARK: - 模型/推理配置

@Observable
class ModelConfig {
    static let selectedModelDefaultsKey = "PhoneClaw.selectedModelID"
    static let enableThinkingDefaultsKey = "PhoneClaw.enableThinking"
    static let preferredBackendDefaultsKey = "PhoneClaw.preferredBackend"
    private static let preferredBackendDefaultGPUMigrationKey = "PhoneClaw.preferredBackendDefaultGPU.v1"
    static let enableSpeculativeDecodingDefaultsKey = "PhoneClaw.enableSpeculativeDecoding"
    static let defaultPreferredBackend = "gpu"

    // 采样参数不再暴露给用户调节。topK/topP/temperature 用 Gemma 4 推荐默认。
    // maxTokens = session 总预算 (输入+输出): openSession 拿它当 session maxTokens。
    // KV cache 现已是 4096 (LiteRTBackend.maxKVTokens, 2026-04-25 从 2048 提上来),
    // 但 maxTokens 一直停在旧 KV=2048 时代的 1500 — web 综合的大证据输入会把它吃光,
    // 输出半句截断 (用户实测 "今天的 AI 新闻" 总结被砍)。提到 2048 (CLI 验证过的好值):
    // 仍在 4096 KV 内, 输出有足够余量; 不增内存 (KV 已按 4096 分配),
    // 也不影响历史裁剪 (reservedOutputTokens 仍 min 到 700)。
    var maxTokens = 2048
    var topK = 64
    var topP = 0.95
    var temperature = 1.0
    var enableThinking = UserDefaults.standard.bool(forKey: enableThinkingDefaultsKey)
    var selectedModelID = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        ?? ModelDescriptor.defaultModel.id
    /// 推理后端偏好: `"gpu"` (Metal, 默认) 或 `"cpu"`. 只 LiteRT 后端有意义;
    /// MLX / 其他后端忽略。切换后会 reload 引擎 (~3-7s), 具体 UX 见 ConfigurationsView。
    var preferredBackend: String = ModelConfig.resolvePreferredBackend()
    /// Gemma 4 MTP speculative decoding 开关。仅 LiteRT + Gemma 4 (.litertlm 含
    /// mtp_drafter section) 上有效。开启后 drafter 占 ~300-400 MB pinned RAM。
    /// 当前 V1 sampler 仅在 sequence_size=1 路径正确，sequence_size>1 时会跑诊断
    /// dump (一次性，stderr) 帮助定位 verifier logits 实际 layout。默认关闭。
    var enableSpeculativeDecoding: Bool = UserDefaults.standard.bool(forKey: enableSpeculativeDecodingDefaultsKey)
    /// System prompt — 由 AgentEngine.loadSystemPrompt() 从 SYSPROMPT.md 注入，不在代码里硬编码。
    var systemPrompt = ""

    private static func resolvePreferredBackend() -> String {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: preferredBackendDefaultsKey)

        guard !defaults.bool(forKey: preferredBackendDefaultGPUMigrationKey) else {
            return stored ?? defaultPreferredBackend
        }

        defaults.set(true, forKey: preferredBackendDefaultGPUMigrationKey)
        guard stored == nil || stored == "cpu" else {
            return stored ?? defaultPreferredBackend
        }

        defaults.set(defaultPreferredBackend, forKey: preferredBackendDefaultsKey)
        return defaultPreferredBackend
    }
}

// MARK: - SYSPROMPT 默认内容（仅在文件不存在时写入磁盘）
//
// 按当前语言从 PromptLocale 取. zh 版字节相同于原硬编码文本 (已经
// PromptLocale foundation commit 里做过 diff 验证), en 版翻译结构对齐。
// 用 var computed 而非 let: 保证用户切换语言后新生成的 SYSPROMPT.md
// 默认内容跟着变 (仅对 "文件不存在" 的首次写入有效, 已有 SYSPROMPT.md
// 不会被覆盖, 除非走到旧版模板的 migration 路径).
var kDefaultSystemPrompt: String { PromptLocale.current.defaultSystemPromptAgent }
