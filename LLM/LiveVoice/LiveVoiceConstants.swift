import Foundation

// MARK: - Live 语音模式常量 (default locale wrapper)
//
// 真正的 prompt 资产现在集中在 `LiveLocale.swift` 的 `LiveLocaleConfig`. 这个文件
// 只是为了向后兼容/便捷访问, 暴露默认 locale (zh-CN) 的常量给:
//   - CLI harness probe (引用 `PromptBuilder.defaultLiveVoiceConstraints` 等)
//   - 旧测试代码
//
// 新代码请通过 `PromptBuilder.buildLiveVoiceSystemPrompt(...)` /
// `PromptBuilder.buildLiveVoiceUserPrompt(...)` 走 i18n 路径, 不要直接引用这些常量.

extension PromptBuilder {

    /// 默认 locale (zh-CN) 的 Live system prompt 全文。
    /// Phase 2 收敛后 Live 只有这一段 prompt，不再分多个 section。
    static var defaultLiveVoiceConstraints: String {
        LiveLocaleConfig.zhCN.systemPrompt
    }

    /// 历史兼容占位。Phase 2 起 vision/userHint/skill 全合并进 systemPrompt，
    /// 这些独立字段不再存在；返回空字符串避免旧 CLI / 测试代码因符号缺失而断裂。
    static var defaultVisionConstraint: String { "" }
    static var defaultLiveUserHint: String { "" }
    static var defaultLiveSkillSuppressionInstruction: String { "" }
    static var defaultSkillInvocationInstruction: String { "" }
}
