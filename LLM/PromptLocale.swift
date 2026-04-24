import Foundation

// MARK: - PhoneClaw Prompt Locale
//
// Phase 2 foundation: 把所有**送给 LLM**的中文指令抽到这个 typed struct 里,
// 按当前语言 (zhHans / en) 二选一。不 replace `tr()` — `tr()` 专门给**UI**
// 文案 (用户看到的 SwiftUI 字符串、错误提示等), `PromptLocale` 专门给
// **prompt** 文案 (模型看到的系统提示、指令模板、时间锚点等)。
//
// 为什么分两套:
//   - UI 文案大多 inline, tr(zh, en) 看完一行就行
//   - Prompt 文案常是多行模板 / 带占位符, 集中管理更好 diff + 审查翻译
//   - 将来要加 few-shot 示例时, 可以按 locale 分集
//
// 设计约束:
//   - 每种 locale 是一个 PromptLocale 实例, zh 版字符串**必须跟原
//     PromptBuilder.swift 硬编码字节相同**, 不做隐式修改 — 改 prompt
//     的正确方式是同时改两种 locale, 不允许某个 locale 落后
//   - 动态拼接 (含 `\(var)`) 用 format 字符串 + String(format:) — 保持
//     PromptBuilder 那层干净, PromptLocale 只存字符串模板
//   - 新增 prompt 时先在这里加 zh/en 字段, 再在 PromptBuilder 引用

struct PromptLocale {

    // MARK: - 语言 metadata (配合时间锚点的 DateFormatter locale)

    /// `DateFormatter.locale` 用的 identifier. zh_CN 保证周几是"周一"不是"Mon"。
    let dateFormatterLocaleIdentifier: String

    // MARK: - Default system prompt

    /// `AgentEngine.kDefaultSystemPrompt` 的内容 (SYSPROMPT.md 首次被创建
    /// 时写入的默认值; 之后用户可以编辑, 我们只管首次种默认)。
    let defaultSystemPromptAgent: String

    /// `PromptBuilder.defaultSystemPrompt` — 短版 persona, 用在 tool follow-up
    /// 等 secondary 推理, 不用 SYSPROMPT.md。
    let defaultSystemPromptShort: String

    // MARK: - Thinking mode

    /// 启用 thinking mode 时要求模型 reasoning + 终答都用指定语言。
    let thinkingLanguageInstruction: String

    // MARK: - Image markers (对话历史渲染)

    /// 历史 turn 里某轮发过图片的占位符 (不重复塞进去)。
    let imageHistoryMarker: String

    /// 图片追问 (Image follow-up) context 的 open/close marker。
    let imageFollowUpContextOpenMarker: String
    let imageFollowUpContextCloseMarker: String

    // MARK: - Time anchor

    /// 时间锚点前缀, `%@` 是格式化后的 "yyyy-MM-dd 周X HH:mm" 字符串。
    let timeAnchorFormat: String

    // MARK: - 短占位符

    /// 当 assistant 回复被中断时, chat bubble 显示的占位符。
    let cancelledReplyPlaceholder: String

    /// 当 assistant 回复为空时, chat bubble 显示的占位符。
    let emptyReplyPlaceholder: String

    /// 首轮 skill-triggering prompt 遇到 context 预算不够时的 hard-reject。
    let hardRejectContextTooLong: String

    // MARK: - 多模态 fallback prompts

    /// 用户只发了图片没发文字时, 默认提问。
    let describeImagePromptFallback: String

    /// 用户只发了音频没发文字时, 默认 intent 前缀。
    let transcribeAudioIntentFallback: String

    /// 包装 audio 的 system message: `关于这段音频: %@`
    let audioContextFormat: String

    /// 图片追问 draft 为空时的 fallback reply。
    let cannotDetermineFromLastImage: String

    // MARK: - Static instances

    static let zhHans = PromptLocale(
        dateFormatterLocaleIdentifier: "zh_CN",

        defaultSystemPromptAgent: kDefaultSystemPromptAgentZh,

        defaultSystemPromptShort: "你是 PhoneClaw，一个运行在本地的私人 AI 助手。你完全运行在设备上，不联网。",

        thinkingLanguageInstruction: "如果启用了思考模式，思考通道和最终回答都必须使用简体中文，不要使用英文。",

        imageHistoryMarker: "[用户在此轮发送了图片]",
        imageFollowUpContextOpenMarker: "[上一轮图片上下文]",
        imageFollowUpContextCloseMarker: "[/上一轮图片上下文]",

        timeAnchorFormat: "当前时间锚点(用于解析\"今天/明天/下午两点\"等相对时间): %@",

        cancelledReplyPlaceholder: "（已中断）",
        emptyReplyPlaceholder: "（无回复）",
        hardRejectContextTooLong: "上下文过长，已无法安全继续。请新开会话或缩短问题。",

        describeImagePromptFallback: "请描述这张图片。",
        transcribeAudioIntentFallback: "请详细转写并描述",
        audioContextFormat: "关于这段音频：%@",
        cannotDetermineFromLastImage: "仅根据上一轮图片回答无法确定。"
    )

    static let en = PromptLocale(
        dateFormatterLocaleIdentifier: "en_US",

        defaultSystemPromptAgent: kDefaultSystemPromptAgentEn,

        defaultSystemPromptShort: "You are PhoneClaw, a private AI assistant running locally on your device. You run entirely offline and never connect to the internet.",

        thinkingLanguageInstruction: "When thinking mode is enabled, both the reasoning channel and the final reply must be in English. Do not use Chinese.",

        imageHistoryMarker: "[User sent an image this turn]",
        imageFollowUpContextOpenMarker: "[Previous image context]",
        imageFollowUpContextCloseMarker: "[/Previous image context]",

        timeAnchorFormat: "Current time anchor (used to resolve relative times like \"today/tomorrow/2pm\"): %@",

        cancelledReplyPlaceholder: "(Cancelled)",
        emptyReplyPlaceholder: "(No reply)",
        hardRejectContextTooLong: "Context is too long to continue safely. Please start a new chat or shorten your question.",

        describeImagePromptFallback: "Please describe this image.",
        transcribeAudioIntentFallback: "Please transcribe and describe this audio in detail",
        audioContextFormat: "About this audio: %@",
        cannotDetermineFromLastImage: "Cannot determine from the previous image answer alone."
    )

    // MARK: - Current

    /// 当前生效的 locale. 读 `LanguageService.shared.current.isChinese`,
    /// 跟 UI `tr()` helper 保持同源。
    static var current: PromptLocale {
        LanguageService.shared.current.isChinese ? .zhHans : .en
    }

    // MARK: - Time anchor 检测

    /// `timeAnchorFormat` 里 `%@` 之前的固定前缀 (用作语言无关的"是否已注入"标记).
    /// 跨 locale 统一用这个 set 来检查, 避免语言切换后重复注入 anchor。
    private static let timeAnchorPrefixes: [String] = [
        zhHans.timeAnchorFormat,
        en.timeAnchorFormat,
    ].map { String($0.prefix { $0 != "%" }) }

    /// 检查一段文本是否已经含有某种 locale 的 time anchor 前缀。
    static func containsTimeAnchor(_ text: String) -> Bool {
        timeAnchorPrefixes.contains { !$0.isEmpty && text.contains($0) }
    }
}

// MARK: - Full-length default system prompts
//
// 挪到文件底部, 避免在上面的 struct literal 里占满屏幕。
// 注意: zh 版必须跟 AgentEngine.swift 旧 kDefaultSystemPrompt 字节相同,
// en 版是同义翻译, 保持 persona / 能力列表 / 结构完全对齐。

// zh 版**必须**跟 AgentEngine.swift 的 kDefaultSystemPrompt 字节相同
// (行结构 / 占位符 / 标点 / 序号). 不允许加意译或整理。
// 占位符 `___DEVICE_SKILLS___` / `___CONTENT_SKILLS___` 由 AgentEngine
// 在运行时替换成实际 skill 列表 — 两种 locale 必须都用这两个占位符。
private let kDefaultSystemPromptAgentZh = """
你是 PhoneClaw，一个运行在本地设备上的私人 AI 助手。你完全离线运行，不联网，保护用户隐私。

你拥有以下两类能力（Skill）：

【设备操作类】（访问 iPhone 硬件或系统数据）
___DEVICE_SKILLS___

【内容处理类】（对文字做变换：翻译/总结/改写 等）
___CONTENT_SKILLS___

调用规则：

▶ 设备操作类 skill：
  - 只有用户明确要求执行某项设备操作时，才调用 load_skill。
  - "配置""信息""看看""帮我查一下"这类含糊词，不足以触发。
  - 闲聊、追问上文、解释已有结果时不调用。

▶ 内容处理类 skill：
  - 只要用户意图是对文字做该类变换（翻译/总结/改写 等），立即调用 load_skill。
  - 即使用户用了"这段""刚才那段""上面"等指代词且没贴出源文本，也必须先调用 load_skill。
    加载后的指令会告诉你如何从对话历史中定位源文本。**不要**先反问用户。

▶ 普通闲聊、追问设备操作结果、解释已经输出的内容：直接回答，不要调用任何 skill。

调用格式：
<tool_call>
{"name": "load_skill", "arguments": {"skill": "能力名"}}
</tool_call>

加载 skill 之后请按其指令执行；拿到工具结果后优先直接给最终答案，不要无谓追问。
用中文回答，简洁实用。
"""

// en 版的翻译原则:
//   - 结构逐行对齐 zh 版 (两类 skill 分类 / 调用规则 / 示例格式),
//     同位置保留 `___DEVICE_SKILLS___` / `___CONTENT_SKILLS___` 占位符
//   - "用中文回答" 翻译成 "Reply in English" — 用目标语言自我指令
//   - 类型标签 (【设备操作类】) 翻译成 [Device Ops] / [Content Processing]
private let kDefaultSystemPromptAgentEn = """
You are PhoneClaw, a private AI assistant running locally on the user's device. You run entirely offline — no internet, no data leaves the device.

You have two categories of abilities (Skills):

[Device Ops] (access iPhone hardware or system data)
___DEVICE_SKILLS___

[Content Processing] (transform text: translate / summarize / rewrite, etc.)
___CONTENT_SKILLS___

Invocation rules:

▶ Device Ops skills:
  - Call load_skill only when the user explicitly asks to perform a device operation.
  - Vague phrases like "config", "info", "check", "help me look up" are not enough to trigger.
  - Do not call during casual chat, follow-up questions, or explaining prior results.

▶ Content Processing skills:
  - Whenever the user's intent is to transform text (translate / summarize / rewrite, etc.), call load_skill immediately.
  - Even if the user uses referents like "this", "that one", "the above" without quoting the source text, you must still call load_skill first.
    The loaded instructions will tell you how to locate the source text from conversation history. **Do not** ask the user first.

▶ Casual chat, follow-up on device operation results, or explaining already-output content: reply directly, do not call any skill.

Invocation format:
<tool_call>
{"name": "load_skill", "arguments": {"skill": "<ability name>"}}
</tool_call>

After loading a skill, follow its instructions; after receiving tool results, prefer to give the final answer directly without unnecessary follow-up questions.
Reply in English, concise and practical.
"""
