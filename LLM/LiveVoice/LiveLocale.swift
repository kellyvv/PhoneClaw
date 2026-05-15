import Foundation

// MARK: - Live 语音模式 i18n 配置
//
// 设计目标: LIVE flow 代码全部用 `LiveLocale.zhCN.config` 这个固定入口。
// 真正的语言切换发生在 `.config` getter 内部 — 它读 LanguageService,
// 系统语言中文返回 .zhCN 数据, 英文返回 .enUS 数据。这样保持 LIVE flow
// 文件 (LiveModeEngine / LiveModeUI / LiveTurnProcessor) 少量改动,
// 同时让 zh / en 走各自的 prompt + persona + 状态文案。
//
// 关键设计点:
//   1. 中英两套 prompt 资产完全独立, 不混读 (TTS 中英混读不自然)。
//   2. PersonaName 各 locale 单语: 中文 "手机龙虾", 英文 "PhoneClaw"。
//   3. PromptBuilder.buildLiveVoiceUserPrompt 拼"persona 提醒"前缀时,
//      用 locale 自己的 userPromptPrefix ("你是" / "You are"), 不再硬编码中文。

enum LiveLocale: String, Sendable {
    case zhCN = "zh-CN"

    /// LIVE flow 调用 `LiveLocale.zhCN.config` 的地方都走这个 getter。
    /// 实际返回哪份数据看 `LanguageService.shared.current` — 生效语言中文拿 .zhCN,
    /// 英文拿 .enUS。case 维持一个 `.zhCN` 是因为 LIVE flow 大量代码
    /// 已经写死了 `LiveLocale.zhCN` / `locale: .zhCN`, 改 enum 形状就要碰
    /// LIVE flow 文件 (跟"流程不改"边界冲突)。让 case 退化成"locale 入口",
    /// 用一个 dynamic getter 换 call site 全部不动。
    var config: LiveLocaleConfig {
        switch LanguageService.shared.current.resolved {
        case .zhHans: return .zhCNData
        case .en:     return .enUSData
        case .auto:   return .zhCNData  // 不可能, .auto 在 LanguageService 里已经被 resolve 掉
        }
    }
}

// MARK: - LiveLocaleConfig

/// 单一 locale 的全部 Live prompt 资产. 所有 string 在该 locale 内自洽,
/// 不依赖其它 locale 的常量.
struct LiveLocaleConfig: Sendable {

    struct StatusStrings: Sendable {
        let preparingPrefix: String
        let preparingLive: String
        let preparing: String
        let liveModelMissing: String
        let audioEngineFailed: String
        let vadUnavailable: String
        let recording: String
        let processing: String
        let listeningPrompt: String
        let loadModelFirst: String
        let initializationFailed: String
        let ended: String
        let speaking: String
        let loadingHeadline: String
        let listeningHeadline: String
        let recordingHeadline: String
        let processingHeadline: String
        let speakingHeadline: String
        let interruptHint: String
    }

    /// LLM 在 Live 自我介绍用的名字. TTS 友好 — 单语, 无英文混读.
    let personaName: String

    /// Live 唯一的 system prompt. 进入 Live 时一次性注入。
    let systemPrompt: String

    /// Live 启动后用于预热 conversation 的首条 user turn.
    let greetingPrompt: String

    /// LiveModeEngine 收到 unexpected tool_call 时, TTS 朗读的口语兜底.
    let fallbackUtterance: String

    /// PromptBuilder 在每轮 user prompt 前面加的"persona 提醒"前缀。
    /// **包含 locale 需要的尾部空格**（英文需要 "You are " 后空格, 中文不需要）,
    /// 这样模板可以写成 `(\(prefix)\(persona))` 不再做语言判断:
    ///   - 中文 "你是"     → 拼出 "(你是手机龙虾) 用户的话"
    ///   - 英文 "You are " → 拼出 "(You are PhoneClaw) what user said"
    let userPromptPrefix: String

    /// Live 状态/提示相关文案。
    let statusStrings: StatusStrings
}

// MARK: - 中文 (zh-CN) 数据

extension LiveLocaleConfig {

    static let zhCNData = LiveLocaleConfig(
        personaName: "手机龙虾",
        systemPrompt: """
        你叫"手机龙虾"，是用户手机上的本地语音助手。
        你正在和用户进行实时语音对话。
        判断用户这句是否说完整：完整就在第一字符输出"✓"加空格再回答；像被打断只输出"○"；像在思考只输出"◐"。"○"和"◐"后不能再输出任何字。
        回答用纯中文口语，自然流畅。回答要有内容、有细节，至少说两三句话。
        如果用户问的是"你能做什么"之类的介绍性问题，举具体例子说明。
        你有摄像头能力，但默认是关闭的，无法看到画面。系统会通知你摄像头的开关状态变化。在收到开启通知前，不要声称能看到任何东西。
        """,
        greetingPrompt: "我们开始吧，用一句简短的中文口语和我打个招呼，再邀请我直接说需求。一句话，不超过 20 个字，不要用任何符号、表情或英文。",
        fallbackUtterance: "抱歉，我刚才没听清，麻烦再说一次。",
        userPromptPrefix: "你是",
        statusStrings: StatusStrings(
            preparingPrefix: "正在准备",
            preparingLive: "正在准备语音对话",
            preparing: "正在准备",
            liveModelMissing: "请先在配置页下载语音模型",
            audioEngineFailed: "音频引擎启动失败",
            vadUnavailable: "语音检测不可用",
            recording: "正在听你说",
            processing: "正在理解",
            listeningPrompt: "我在听，请说话",
            loadModelFirst: "请先加载模型",
            initializationFailed: "语音模式初始化失败",
            ended: "语音对话已结束",
            speaking: "正在回答",
            loadingHeadline: "正在加载",
            listeningHeadline: "我在听",
            recordingHeadline: "正在听你说",
            processingHeadline: "正在理解",
            speakingHeadline: "正在回答",
            interruptHint: "可以直接打断"
        )
    )

    /// Backward-compat alias. LiveVoiceConstants 还引用 `.zhCN`, 保留指针。
    static var zhCN: LiveLocaleConfig { zhCNData }

    // MARK: - 英文 (en-US) 数据

    static let enUSData = LiveLocaleConfig(
        personaName: "PhoneClaw",
        systemPrompt: """
        You are an on-device voice assistant called PhoneClaw, running locally on the user's phone.
        You are having a real-time voice conversation with the user.

        Decide whether the user's utterance is complete: if it is complete, output "✓" then a space then your reply at the very start; if the user got cut off, output only "○"; if the user is still thinking, output only "◐". After "○" or "◐" output no further characters.

        Reply in natural conversational English, smooth and casual. Give substance and detail — at least two or three sentences.

        IMPORTANT — sentence openers: never begin a reply with the bare word "PhoneClaw". Always start with natural English: "I'm", "I", "Hi", "Hey", "Sure", "Yes", "Of course", "Let me", etc. When introducing yourself, say "I'm PhoneClaw, ..." or "Hi, I'm PhoneClaw — ..." but do NOT start with "PhoneClaw" alone.

        For introductory questions like "what can you do", give specific concrete examples.

        You have camera capability, but the camera is off by default and you cannot see anything. The system will notify you when the camera state changes. Until you receive an "on" notification, do not claim to see anything.
        """,
        greetingPrompt: "Let's begin. Greet me in one short casual English sentence and invite me to say what I need. **Start your reply with \"Hi\" or \"Hey\"**, never start with the word \"PhoneClaw\". One sentence only, under 20 words, no symbols, no emoji, no Chinese.",
        fallbackUtterance: "Sorry, I didn't catch that. Could you say it again?",
        // 英文留空 — 不再加 (You are PhoneClaw) 这个 per-turn 提醒。
        // 中文里 (你是手机龙虾) 是自然语序模型不会当 label, 但英文 "(You are PhoneClaw)"
        // 在 Gemma E2B 英文模式下被当成 stage direction, 强化了"以 PhoneClaw 开头答复"的鹦鹉模式。
        // 系统 prompt 已经在 conversation 开场注入并保留在 KV cache 里, 不需要每轮再提醒。
        userPromptPrefix: "",
        statusStrings: StatusStrings(
            preparingPrefix: "Preparing",
            preparingLive: "Preparing voice mode",
            preparing: "Preparing",
            liveModelMissing: "Please download voice models in Settings first",
            audioEngineFailed: "Audio engine failed to start",
            vadUnavailable: "Voice detection unavailable",
            recording: "Listening",
            processing: "Thinking",
            listeningPrompt: "I'm listening, go ahead",
            loadModelFirst: "Please load the model first",
            initializationFailed: "Voice mode init failed",
            ended: "Voice mode ended",
            speaking: "Replying",
            loadingHeadline: "Loading",
            listeningHeadline: "I'm listening",
            recordingHeadline: "Listening",
            processingHeadline: "Thinking",
            speakingHeadline: "Replying",
            interruptHint: "You can interrupt me"
        )
    )
}
