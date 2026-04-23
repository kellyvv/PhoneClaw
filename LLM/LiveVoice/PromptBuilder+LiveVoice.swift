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
    /// 每轮带一句极短的 persona 提醒, 防止 E4B 模型自我认同漂移 (Gemma 4 → 手机龙虾).
    /// 摄像头状态由 notifyCameraStateChanged() 事件驱动注入, 不在每条消息里重复.
    static func buildLiveVoiceUserPrompt(
        userTranscript: String,
        locale: LiveLocale = .zhCN,
        hasVision: Bool
    ) -> String {
        _ = hasVision
        let persona = locale.config.personaName
        return "(你是\(persona)) \(userTranscript)"
    }
}
