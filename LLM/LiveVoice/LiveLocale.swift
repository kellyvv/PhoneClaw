import Foundation

// MARK: - Live 语音模式 i18n 配置
//
// 设计目标: 加新语言只在本文件加 `case` + `LiveLocaleConfig` 实例, 其它代码不变.
//
// 关键设计点:
//   1. PersonaName 是核心. TTS 不能混读 (中英混读卡顿不自然), 所以中文场景必须用
//      "手机龙虾", 英文场景必须用 "PhoneClaw", 各自单语.
//   2. SYSPROMPT.md 里的英文 persona 名字 (`PhoneClaw`) 在 Live 注入时会被
//      `personaAliasesToReplace` 替换成 locale 自己的 personaName.
//      这样 LLM 看到的 system prompt 里**只有一个 persona 名字**, 不会出现
//      Chat UI 主 persona 和 Live persona 冲突 (E4B 在冲突时会保守回避两者,
//      真机 2026-04-16 验证).
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

    // MARK: Persona

    /// LLM 在 Live 自我介绍用的名字. TTS 友好 — 单语, 无英文混读.
    let personaName: String

    /// SYSPROMPT.md 中需要被替换为 `personaName` 的字面 (通常是其它语言的 persona 名).
    /// 例如 zh-CN 把 "PhoneClaw" 替换为 "手机龙虾", 让 system prompt 中只剩中文 persona,
    /// 消除 Chat UI 和 Live 模式 persona 冲突.
    let personaAliasesToReplace: [String]

    // MARK: Prompt 模板

    /// 语音约束模板. `{name}` 占位会被替换成 `personaName`.
    /// 包含 marker 规则 (✓/○/◐) + 口语风格 + persona 锚点.
    let voiceConstraintsTemplate: String

    /// 视觉感知约束 (有摄像头时拼到 system prompt 末尾, vision constraint 之前).
    let visionConstraint: String

    /// Vision turn 的 user message 末尾守卫. Gemma 4 4bit 对 system prompt 里的
    /// "必须用 X 开头/不要说 Y" 这类约束跟随能力弱; 紧贴 generation 的 user message
    /// 末尾指令影响最强. 这条只在有 frame 的轮次拼接, 防止模型把实时画面误称为
    /// "图片/照片/这张图".
    let visionUserGuard: String

    /// 当前 user 文本末尾追加的 hint, 重申 TTS 风格约束.
    /// 不进 history (engine 侧 trim), 每轮都重新拼.
    let userHint: String

    // MARK: Skill 通道 (阶段 1/2 抑制 + 阶段 3 启用)

    /// MVP 阶段 (`preloadedSkills` 为空) 拼到 system prompt 末尾的强抑制指令.
    /// 因为 SYSPROMPT.md 通常含 `<tool_call>` 调用格式示例, 不压制的话模型会
    /// 在 Live 场景自发输出 tool_call (真机 2026-04-16 实测).
    let skillSuppressionInstruction: String

    /// 阶段 3 启用 skill 调用通道时, 替代 skillSuppressionInstruction 拼到 system prompt 末尾.
    let skillInvocationInstruction: String

    // MARK: Engine fallback

    /// LiveModeEngine 收到 unexpected tool_call 时, TTS 朗读的口语兜底.
    /// 用 locale 自己的语言, 用户听到自然语言提示, 不会听到一片寂静.
    let fallbackUtterance: String

    // MARK: Computed

    /// 渲染 voiceConstraintsTemplate, 把 `{name}` 占位替换成 `personaName`.
    var voiceConstraints: String {
        voiceConstraintsTemplate.replacingOccurrences(of: "{name}", with: personaName)
    }
}

// MARK: - 默认: 中文 (zh-CN)

extension LiveLocaleConfig {

    static let zhCN = LiveLocaleConfig(
        personaName: "手机龙虾",
        personaAliasesToReplace: ["PhoneClaw"],
        voiceConstraintsTemplate: """
        你正在进行实时语音对话，必须先判断用户这句话在对话上是否已经说完整。若已经完整，第一字符必须输出 `✓`，后面紧跟一个空格和你的正常回答；若用户像是被打断、几秒内还会继续，只输出 `○`；若用户像是在思考、需要更久，只输出 `◐`。`○` 和 `◐` 后面绝对不能再输出任何字。正常回答时用纯中文口语，根据用户意图决定详略：默认简短（一两句），当用户要求"详细""展开""多说一点"等时可以展开，但始终保持口语化、多用中文逗号句号，禁止英文和 markdown 符号。你叫"{name}"，自我介绍时请说"{name}"，不要说英文名字（包括缩写、品牌名、技术术语），因为 TTS 中英文混读不自然。
        """,
        visionConstraint: "你通过手机摄像头实时看到画面（视频流，不是图片）。",
        visionUserGuard: "\n（你通过我的手机摄像头实时看到画面，这是视频流不是图片附件。回答时直接说看到了什么，不要出现「图」「片」「照」「张」等字。）",
        userHint: "\n[语音模式] 回答会被朗读出来。用纯中文口语回答，根据用户意图决定详略（默认简短，用户明确要求详细/展开时可多说几句），禁止英文和markdown符号。多用中文逗号和句号，方便语音自然分段播放。不要在回答开头自报名字。",
        skillSuppressionInstruction: """
        【当前模式: 实时语音】本轮严禁输出 `<tool_call>`, 严禁提及 Skill / load_skill / 工具调用. 上文所有 Skill 调用规则本轮一律不适用. 直接用中文口语回答用户.
        """,
        skillInvocationInstruction: """
        当你需要调用工具时，输出 `<tool_call>{"name":"...", "arguments":{...}}</tool_call>` 后立即停止。不要在 tool_call 前后多说话，工具执行后我会用结果再请你总结给用户。
        """,
        fallbackUtterance: "抱歉，我刚才没听清，麻烦再说一次。"
    )

    // MARK: 未来扩展示意 (英文 locale)
    //
    // static let enUS = LiveLocaleConfig(
    //     personaName: "PhoneClaw",
    //     personaAliasesToReplace: ["手机龙虾"],   // 反向替换
    //     voiceConstraintsTemplate: """
    //     You are in a real-time voice conversation. ... Your name is "{name}". ...
    //     """,
    //     ...
    // )
}
