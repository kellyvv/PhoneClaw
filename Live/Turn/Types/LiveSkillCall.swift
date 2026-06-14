import Foundation

/// LLM 通过 `<tool_call>{...}</tool_call>` 输出的工具调用请求.
///
/// LIVE 普通聊天轮不应触发；只有 `LiveTurnProcessor.enableSkillInvocation = true`
/// 且本轮路由命中工具型 Skill、注入 LIVE_SKILL_CONTRACT 后才会被执行.
///
/// `arguments` 用 `[String: Any]` 是因为 LLM 输出的 JSON 结构由各 skill 的
/// schema 决定, 强类型化没意义. 等阶段 3 接入 ToolRegistry 执行时, 在 tool
/// handler 内部做类型校验即可.
struct LiveSkillCall: @unchecked Sendable {
    let name: String
    let arguments: [String: Any]
}
