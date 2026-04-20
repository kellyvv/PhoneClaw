import Foundation

// MARK: - Live 语音模式 i18n 配置
//
// 设计目标: 加新语言只在本文件加 `case` + `LiveLocaleConfig` 实例, 其它代码不变.
//
// 关键设计点:
//   1. Live 是一套独立 prompt 体系. 为保证 TTS 朗读自然, zh-CN 场景的 prompt
//      资产必须是纯中文, 不再继承 Chat 的通用 system prompt.
//   2. PersonaName 是核心. TTS 不能混读 (中英混读卡顿不自然), 所以中文场景必须用
//      "手机龙虾", 英文场景必须用 "PhoneClaw", 各自单语.
//   3. 各 prompt 模板 (voiceConstraints) 用 `{name}` 占位, 渲染时替换为 personaName,
//      避免 personaName 字面和模板正文漂移.

/// Live 模式支持的 locale. 加新语言:
///   1. 加一个 case
///   2. 在 `LiveLocaleConfig` extension 里加对应静态实例
///   3. 在 `config` switch 里加 case 映射
enum LiveLocale: String, Sendable {
    case zhCN = "zh-CN"
    // case enUS = "en-US"   // ★ 未来扩展示意

    var config: LiveLocaleConfig {
        switch self {
        case .zhCN: return .zhCN
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

    // MARK: Persona

    /// LLM 在 Live 自我介绍用的名字. TTS 友好 — 单语, 无英文混读.
    let personaName: String

    // MARK: Prompt 模板

    /// Live 唯一的 system prompt. 进入 Live 时一次性注入，后续轮次只发用户文本，
    /// 不再做多段拼装、不再做禁词 / persona 替换 / 占位渲染。
    /// 收敛历史：试过 base + voiceConstraints + modeSection + skillSection + 禁词 +
    /// vision guard 的多段方案，禁词在 Gemma 4 4bit 上触发"白熊效应"反而引爆漂移
    /// (实测越禁 Gemma/Google 模型越自报)。结论是只留一段最小 prompt，剩下的事交给模型。
    let systemPrompt: String

    /// Live 启动后用于预热 conversation 的首条 user turn.
    let greetingPrompt: String

    // MARK: Engine fallback

    /// LiveModeEngine 收到 unexpected tool_call 时, TTS 朗读的口语兜底.
    /// 用 locale 自己的语言, 用户听到自然语言提示, 不会听到一片寂静.
    let fallbackUtterance: String

    /// Live 状态/提示相关文案. Phase 1 把会被用户看到或听到的自然语言字符串
    /// 收回 locale 配置，避免继续散在 engine / UI 里。
    let statusStrings: StatusStrings
}

// MARK: - 默认: 中文 (zh-CN)

extension LiveLocaleConfig {

    static let zhCN = LiveLocaleConfig(
        personaName: "手机龙虾",
        systemPrompt: """
        你叫"手机龙虾"，是用户手机上的本地语音助手。
        你正在和用户进行实时语音对话。
        判断用户这句是否说完整：完整就在第一字符输出"✓"加空格再回答；像被打断只输出"○"；像在思考只输出"◐"。"○"和"◐"后不能再输出任何字。
        回答用纯中文口语，简短自然。
        """,
        greetingPrompt: "我们开始吧，用一句简短的中文口语和我打个招呼，再邀请我直接说需求。一句话，不超过 20 个字，不要用任何符号、表情或英文。",
        fallbackUtterance: "抱歉，我刚才没听清，麻烦再说一次。",
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

    // MARK: 未来扩展示意 (英文 locale)
    //
    // static let enUS = LiveLocaleConfig(
    //     personaName: "PhoneClaw",
    //     baseSystemPrompt: "...",
    //     voiceConstraintsTemplate: """
    //     You are in a real-time voice conversation. ... Your name is "{name}". ...
    //     """,
    //     ...
    // )
}
