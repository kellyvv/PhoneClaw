import Foundation

/// LLM 通过 `<tool_call>{...}</tool_call>` 输出的工具调用请求.
///
/// 阶段 1 MVP 里永远不会触发 (LiveTurnProcessor.enableSkillInvocation = false),
/// 但类型先定好, 阶段 3 打开 tool_call 通道时直接可用.
///
/// `arguments` 用 `[String: Any]` 是因为 LLM 输出的 JSON 结构由各 skill 的
/// schema 决定, 强类型化没意义. 等阶段 3 接入 ToolRegistry 执行时, 在 tool
/// handler 内部做类型校验即可.
struct LiveSkillCall: @unchecked Sendable {
    let name: String
    let arguments: [String: Any]
}
