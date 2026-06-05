import Foundation

// MARK: - Live 语音模式 prompt builder
//
// 为什么独立 extension 文件:
//   主 PromptBuilder.swift 放通用 prompt 构建 (light / full Agent / multimodal).
//   Live 语音有一套自己的拼接逻辑 (手写 <|turn> 模板 + marker 约束 + vision
//   条件 + skill 通道 + i18n persona override), 合进去会让 PromptBuilder.swift
//   职责过杂.
//
// 现在 Live 统一走 LiteRT 的 persistent multimodal conversation:
//   - one-time system prompt 在 openConversation(...) 时注入
//   - 每一轮只发送新的 user text / image payload
//   - 历史由 conversation 自己维护, 不再手写 <|turn> 模板或 delta prompt
//
// i18n:
//   接受 `locale: LiveLocale` 参数, 不同语言场景下使用 locale 自己的 Live prompt 资产.
//   从 Phase 1 开始，Live 不再继承 Chat 的通用 system prompt，避免把英文、
//   工具协议和不适合 TTS 的内容带进语音模式。

extension PromptBuilder {

    /// Live conversation 的一次性 system prompt. 进入 Live 时调用一次,
    /// 后续轮次只发送 user text / media. 直接返回 locale 的单一 systemPrompt,
    /// 不再做多段拼装、禁词列表、占位渲染.
    /// 历史教训: 拼装越多, 在 Gemma 4 4bit 上 persona 漂移越严重 (白熊效应).
    static func buildLiveVoiceSystemPrompt(
        userSystemPrompt: String?,
        locale: LiveLocale = .zhCN,
        preloadedSkills: [PreloadedSkill] = []
    ) -> String {
        _ = userSystemPrompt
        _ = preloadedSkills
        return locale.config.systemPrompt
    }

    /// 当前 Live turn 的纯文本 user message.
    /// 历史: 中文场景每轮带一句极短 persona 提醒 `(你是手机龙虾)` 防止 E4B 模型自我认同漂移。
    /// 英文场景实测下来这个 wrapping 反而有害 — Gemma E2B 把 `(You are PhoneClaw)` 当 stage
    /// direction 强化成"以 PhoneClaw 开头答复"鹦鹉模式 (中文不会, 是 E2B 中英行为差异 +
    /// 单词级 persona name 容易当 sentence opener)。
    ///
    /// 现在按 locale.config.userPromptPrefix 是否为空决定是否加 wrapping:
    ///   - 中文: prefix="你是" → "(你是手机龙虾) 用户的话"      (保留原有抗漂移 wrap)
    ///   - 英文: prefix=""    → "用户的话"                      (不 wrap, 系统 prompt 已经够)
    ///
    /// **camera-off marker**: 原来用 `notifyCameraStateChanged` 在 KV 里 prefill 系统消息
    /// 来告诉模型摄像头状态。但这条路径会跟 greeting / 用户轮次的 generateLive 并发, 撞到
    /// MiniCPM-V 原生 ctx → 闪退。改为按需在 user prompt 里贴一个 `(摄像头未开启)` marker:
    /// 仅当 `cameraOff == true` (即"摄像头本会话开过但当前已关") 时追加, 防止模型基于陈旧
    /// 视觉 KV 幻觉。从未开过摄像头的会话不加, 避免每轮多一句噪音。
    ///
    /// **vision 轮特殊处理**：当 hasVision=true 时, 跳过 persona wrapping, 只加很短的
    /// 视觉轮提示。
    /// 真实场景观察 (MiniCPM-V 4.6, 0.8B): "(你是手机龙虾) 你现在可以看到什么"
    /// 这种 user message 会被小模型当成"关于身份的元指令", 模型不去看图, 反而
    /// 输出身份/状态类回答 (例如复述上一条 camera-on 系统通知)。视觉查询本身就
    /// 不需要 persona 提醒 — 图像信号足够强 + system prompt 里也有 persona。
    /// 但完全裸传 transcript 时, 小模型会把"你现在能看到什么"误判成"用户仍在思考"
    /// 并输出 ◐, 导致 Live 层按 incomplete turn suppress assistant reply。因此这里
    /// 只提醒"本轮带画面, 这是完整视觉问题", 不再注入身份或摄像头状态通知。
    /// Gemma 4 VLM 上同样适用 (VLM 训练数据里的 image+query 一般不带身份 wrap)。
    static func buildLiveVoiceUserPrompt(
        userTranscript: String,
        locale: LiveLocale = .zhCN,
        hasVision: Bool,
        cameraOff: Bool = false
    ) -> String {
        let cfg = locale.config
        let cameraOffNote: String = {
            guard cameraOff else { return "" }
            return cfg.cameraOffMarker
        }()

        if hasVision {
            // 视觉轮: 不 wrap persona, 只给一个轻量 task hint, 避免被 marker parser
            // 误判成 ◐/○ 后吞掉回答。hasVision=true 时模型直接看图, 不需要也不该带
            // cameraOffNote (本来就有画面)。
            return cfg.visionTaskHint + userTranscript
        }
        guard !cfg.userPromptPrefix.isEmpty else {
            // locale 选择不带 per-turn persona 提醒 (e.g. 英文)
            return cameraOffNote + userTranscript
        }
        // 非视觉轮: 按 locale 维持原有 persona wrapping。
        // userPromptPrefix 已包含 locale 需要的尾部空格 (中文 "你是" 不带空格连接)。
        return "\(cameraOffNote)(\(cfg.userPromptPrefix)\(cfg.personaName)) \(userTranscript)"
    }
}
