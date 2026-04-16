import Foundation

// MARK: - Live 语音模式常量 (default locale wrapper)
//
// 真正的 prompt 资产现在集中在 `LiveLocale.swift` 的 `LiveLocaleConfig`. 这个文件
// 只是为了向后兼容/便捷访问, 暴露默认 locale (zh-CN) 的常量给:
//   - CLI harness probe (引用 `PromptBuilder.defaultLiveVoiceConstraints` 等)
//   - 旧测试代码
//
// 新代码请通过 `PromptBuilder.buildLiveVoicePrompt(... locale: ...)` 走 i18n 路径,
// 不要直接引用这些常量.

extension PromptBuilder {

    /// 默认 locale (zh-CN) 的 voice constraints. 已渲染好 `{name}` 占位.
    static var defaultLiveVoiceConstraints: String {
        LiveLocaleConfig.zhCN.voiceConstraints
    }

    /// 默认 locale 的 vision constraint.
    static var defaultVisionConstraint: String {
        LiveLocaleConfig.zhCN.visionConstraint
    }

    /// 默认 locale 的 user turn hint.
    static var defaultLiveUserHint: String {
        LiveLocaleConfig.zhCN.userHint
    }

    /// 默认 locale 的 skill suppression instruction (MVP 阶段抑制 tool_call 用).
    static var defaultLiveSkillSuppressionInstruction: String {
        LiveLocaleConfig.zhCN.skillSuppressionInstruction
    }

    /// 默认 locale 的 skill invocation instruction (阶段 3 启用 tool_call 通道用).
    static var defaultSkillInvocationInstruction: String {
        LiveLocaleConfig.zhCN.skillInvocationInstruction
    }
}
