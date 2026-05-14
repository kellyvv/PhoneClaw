import Foundation
import CoreImage

// MARK: - AgentOrchestrator
//
// 路由 / Prompt 构建 / 工具调用执行的逻辑分组入口。Plan §3.2 把这块画成
// 一个独立类持有 Router/Planner/ToolChain/PromptBuilder。
//
// 当前 v1.3 实现选择:作为 AgentEngine 上的 façade 而不是独立 class。
// 这样:
//   - 单元测试需要 Orchestrator 入口时,可以 new AgentOrchestrator(engine: ...)
//     拿到三个核心 API 的 stable 签名
//   - 实际工作仍然 forward 到现有 extension AgentEngine 方法
//     (Router.swift / Planner.swift / ToolChain.swift)
//   - 不需要把 ~2000 行 extension 重组成 class,也不需要把共享状态
//     (messages / config / inference / coordinator) 改成显式依赖注入
//
// 这是务实的折中:plan §3.2 承诺的"逻辑分组"得到兑现,但避免了为了
// conceptual cleanness 做的大重组。如果未来要做真正的独立测试 (mock engine),
// 这里的三个 API 已经稳定,可以扩展实现而不破坏调用方。

@MainActor
final class AgentOrchestrator {

    /// 持有 engine 引用以便 forward 到现有 extension 方法。
    /// 不持有 strong reference,避免循环引用。AgentEngine 自己控制生命周期。
    private unowned let engine: AgentEngine

    init(engine: AgentEngine) {
        self.engine = engine
    }

    // MARK: - Plan (Router + 决策)

    /// 路由匹配: 用户输入对应哪些 skill。
    /// 转发到 Router.swift 的实现。
    func matchedSkillIds(for userQuestion: String) -> [String] {
        engine.matchedSkillIds(for: userQuestion)
    }

    /// 决定是否使用完整 Agent prompt(含 tool schema)。
    /// 转发到 Router.swift 的实现。
    func shouldUseToolingPrompt(for userQuestion: String) -> Bool {
        engine.shouldUseToolingPrompt(for: userQuestion)
    }

    // MARK: - Tool Calls

    /// 解析 LLM 输出中的 tool_call XML 结构。
    /// 转发到 ToolCallParser.swift 的实现。
    func parseToolCall(_ text: String) -> (name: String, arguments: [String: Any])? {
        engine.parseToolCall(text)
    }

    /// 执行 tool chain(可能多轮: tool → result → LLM → tool → ...)。
    /// 转发到 ToolChain.swift 的实现。
    func executeToolChain(
        prompt: String,
        fullText: String,
        userQuestion: String,
        images: [CIImage]
    ) async {
        await engine.executeToolChain(
            prompt: prompt,
            fullText: fullText,
            userQuestion: userQuestion,
            images: images
        )
    }

    // MARK: - Planner

    /// 触发多 skill planner(matched skills >= 2 时)。
    /// 转发到 Planner.swift 的实现。
    /// 返回 true 表示 planner 路径已处理完整 turn,调用方不需要继续 streaming。
    func executePlannedSkillChainIfPossible(
        prompt: String,
        userQuestion: String,
        images: [CIImage]
    ) async -> Bool {
        await engine.executePlannedSkillChainIfPossible(
            prompt: prompt,
            userQuestion: userQuestion,
            images: images
        )
    }
}

// MARK: - AgentEngine convenience

extension AgentEngine {
    /// 懒加载的 orchestrator façade。供 UI 层或 unit-test 拿稳定 API。
    /// 内部仍然直接调 extension AgentEngine 方法 — 这只是个分组入口。
    var orchestrator: AgentOrchestrator {
        AgentOrchestrator(engine: self)
    }
}
