import Foundation

// MARK: - 模型/推理配置

@Observable
class ModelConfig {
    static let selectedModelDefaultsKey = "PhoneClaw.selectedModelID"
    static let enableThinkingDefaultsKey = "PhoneClaw.enableThinking"
    static let preferredBackendDefaultsKey = "PhoneClaw.preferredBackend"
    static let enableSpeculativeDecodingDefaultsKey = "PhoneClaw.enableSpeculativeDecoding"

    // 采样参数不再暴露给用户调节 — 跟 KV cache = 2048 的现实对齐:
    //   maxTokens 1500 留 ~500 给输入; topK/topP/temperature 用 Gemma 4 推荐默认。
    var maxTokens = 1500
    var topK = 64
    var topP = 0.95
    var temperature = 1.0
    var enableThinking = UserDefaults.standard.bool(forKey: enableThinkingDefaultsKey)
    var selectedModelID = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        ?? ModelDescriptor.defaultModel.id
    /// 推理后端偏好: `"gpu"` (Metal) 或 `"cpu"` (默认). 只 LiteRT 后端有意义;
    /// MLX / 其他后端忽略。切换后会 reload 引擎 (~3-7s), 具体 UX 见 ConfigurationsView。
    /// 默认 CPU: Sideloadly 免费签名的 App 内存上限较低, GPU + E4B 的 Metal buffer
    /// 会 OOM; CPU 更稳妥, 用户可按需切到 GPU。
    var preferredBackend: String = UserDefaults.standard.string(forKey: preferredBackendDefaultsKey)
        ?? "cpu"
    /// Gemma 4 MTP speculative decoding 开关。仅 LiteRT + Gemma 4 (.litertlm 含
    /// mtp_drafter section) 上有效。开启后 drafter 占 ~300-400 MB pinned RAM。
    /// 当前 V1 sampler 仅在 sequence_size=1 路径正确，sequence_size>1 时会跑诊断
    /// dump (一次性，stderr) 帮助定位 verifier logits 实际 layout。默认关闭。
    var enableSpeculativeDecoding: Bool = UserDefaults.standard.bool(forKey: enableSpeculativeDecodingDefaultsKey)
    /// System prompt — 由 AgentEngine.loadSystemPrompt() 从 SYSPROMPT.md 注入，不在代码里硬编码。
    var systemPrompt = ""
}

// MARK: - SYSPROMPT 默认内容（仅在文件不存在时写入磁盘）
//
// 按当前语言从 PromptLocale 取. zh 版字节相同于原硬编码文本 (已经
// PromptLocale foundation commit 里做过 diff 验证), en 版翻译结构对齐。
// 用 var computed 而非 let: 保证用户切换语言后新生成的 SYSPROMPT.md
// 默认内容跟着变 (仅对 "文件不存在" 的首次写入有效, 已有 SYSPROMPT.md
// 不会被覆盖, 除非走到旧版模板的 migration 路径).
var kDefaultSystemPrompt: String { PromptLocale.current.defaultSystemPromptAgent }
