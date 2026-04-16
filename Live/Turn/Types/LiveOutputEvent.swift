import Foundation

/// LiveTurnProcessor → LiveModeEngine 之间的唯一交流协议.
///
/// 所有 live turn 里可能发生的事情都归纳到这几个 case, engine 侧用一个
/// exhaustive switch 处理干净. 新增输出类型只需在这里扩 case, engine
/// 会被编译器强制补齐分支.
enum LiveOutputEvent: Sendable {

    /// 首个非空白 token 是 marker. engine 根据 marker 决定:
    ///   - `.complete`    → 继续接 `.speechToken`, TTS 朗读
    ///   - `.interrupted` → 停止本轮, 退回 listening, 不朗读
    ///   - `.thinking`    → 停止本轮, 退回 listening, 不朗读
    case marker(LiveMarker)

    /// 要朗读给用户的 token 增量. engine 侧接 sanitizer → ttsQueue.
    case speechToken(String)

    /// 架构预留 — 阶段 3 打开 tool_call 通道后, LLM 输出的
    /// `<tool_call>...</tool_call>` 被 LiveOutputParser 截获, emit 这个
    /// 事件给 engine. engine 交给 ToolRegistry 执行, 然后再启动第二轮
    /// LLM inference 做结果口语化总结.
    case skillCall(LiveSkillCall)

    /// 架构预留 — 阶段 3 工具执行完, 第二轮 LLM inference 对结果的口语
    /// 总结输出. engine 把 summary 推给 TTS.
    case skillResult(String)

    /// 流结束. engine 侧要 flush sanitizer 的残余, 转 turnPhase 回 listening.
    case done
}
