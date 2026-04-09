import Foundation

extension AgentEngine {

    // MARK: - 通用工具

    func uniqueStringsPreservingOrder(_ values: [String]) -> [String] {
        Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    // MARK: - Skill 触发匹配

    /// 仅依赖 SKILL.md 的 triggers / allowedTools 字段, 零硬编关键词。
    ///
    /// 支持 **sticky routing**: 如果当前消息不含任何 trigger, 但最近 history
    /// 里有活跃的 skill 上下文 (skillResult 或系统卡片里带 skillName),
    /// 认为用户在对同一个 skill 的多轮对话中做 follow-up, 继续路由到那个 skill。
    /// 这样 "明天下午14点的" 这种纯补全消息也能命中上一轮的 calendar skill,
    /// 避免落到 light 路径丢失 skill 能力。
    func matchedSkillIds(for userQuestion: String) -> [String] {
        let normalizedQuestion = userQuestion.lowercased()
        guard !normalizedQuestion.isEmpty else { return [] }

        var matched: [String] = []
        for entry in skillEntries where entry.isEnabled {
            let skillId = entry.id
            let lowercasedNames = [
                skillId.lowercased(),
                entry.name.lowercased()
            ]

            var isMatch = lowercasedNames.contains { normalizedQuestion.contains($0) }
            if !isMatch,
               let definition = skillRegistry.getDefinition(skillId) {
                isMatch = definition.metadata.triggers.contains { trigger in
                    let normalizedTrigger = trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    return !normalizedTrigger.isEmpty && normalizedQuestion.contains(normalizedTrigger)
                } || definition.metadata.allowedTools.contains { toolName in
                    normalizedQuestion.contains(toolName.lowercased())
                }
            }

            if isMatch {
                matched.append(skillId)
            }
        }

        // Sticky routing: 当前消息没命中任何 trigger, 但最近 history 里有
        // 活跃 skill 上下文 -> 继续使用该 skill。
        //
        // E2B 是产品的"轻量款", 定位 = 聊天 / 翻译 / 单轮查询, 不做多轮工具
        // 对话。默认用户只装一个模型; 选 E2B 的用户冲着小体积 + 快反应来,
        // 不是"降级版 E4B"。对 E2B 关闭 sticky, 让多轮补全落到 light 路径
        // 当普通聊天处理, 避免模型在不擅长的任务上翻车后产生"能调工具的
        // 假象"。这不是 fallback, 是定位差异 —— E4B 才做多轮 agent。
        let isLightweightModel = llm.selectedModel.id.contains("e2b")
        if matched.isEmpty, !isLightweightModel, let stickySkillId = recentActiveSkillId() {
            matched.append(stickySkillId)
        }

        return uniqueStringsPreservingOrder(matched)
    }

    /// 在"上一轮 user turn"范围内查找活跃的 skill 上下文。
    ///
    /// 语义边界: 从最后一条 user message 倒着扫到上一条 user message 之间,
    /// 这一段消息是"上一轮 user turn 触发的所有 agent 行为"。在这个范围内
    /// 找任何 .skillResult 或 .system(skillName) 消息, 第一个匹配即返回。
    ///
    /// 跨越上一条 user message 后停止 — 再往前的 skill 上下文已经是更早
    /// 的对话, 不再相关。
    ///
    /// 为什么不用固定窗口 (suffix(4))?
    ///   一个完整 agent loop 会 append 6-10 条消息 (load_skill, identified,
    ///   loaded, skillResult, executing, done, follow-up assistant 等),
    ///   固定窗口 4 经常错过 skill 上下文, 导致多轮对话失去 sticky 能力。
    ///   语义边界与 message 数量解耦, 任何长度的 agent loop 都能正确接住。
    ///
    /// 这是纯框架层判定 — 不感知任何具体 skill 名, 不硬编任何业务字符串。
    private func recentActiveSkillId() -> String? {
        var sawCurrentUser = false
        for msg in messages.reversed() {
            if msg.role == .user {
                if sawCurrentUser {
                    // 跨越了上一条 user message, 停止扫描
                    return nil
                }
                sawCurrentUser = true
                continue
            }
            // .assistant 也参与: 当 Router 在一轮里匹配到 skill 但 LLM 没调 tool
            // (只追问澄清), 我们给 assistant message 打了 skillName, 这样 sticky
            // 能接住下一轮的补全输入。
            guard (msg.role == .skillResult || msg.role == .system || msg.role == .assistant),
                  let name = msg.skillName, !name.isEmpty else {
                continue
            }

            // name 可能是 skill id (如 "calendar") 或 tool name (如 "calendar-create-event")。
            // 优先作为 skill id 解析; 不行再作为 tool name 反查 skill id。
            let asSkillId = skillRegistry.canonicalSkillId(for: name)
            if let def = skillRegistry.getDefinition(asSkillId), def.isEnabled {
                return asSkillId
            }
            if let skillId = skillRegistry.findSkillId(forTool: name),
               let def = skillRegistry.getDefinition(skillId),
               def.isEnabled {
                return skillId
            }
        }
        return nil
    }

    func canonicalSkillSelectionEntry(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let directSkillId = skillRegistry.canonicalSkillId(for: trimmed)
        if skillEntries.contains(where: { $0.isEnabled && $0.id == directSkillId }) {
            return directSkillId
        }

        let normalizedToolName = canonicalToolName(
            trimmed
                .replacingOccurrences(of: "_", with: "-")
                .lowercased(),
            arguments: [:]
        )

        for entry in skillEntries where entry.isEnabled {
            let toolNames = Set(registeredTools(for: entry.id).map(\.name))
            if toolNames.contains(normalizedToolName) {
                return entry.id
            }
        }

        return nil
    }

    // MARK: - 路由决策

    func shouldUseToolingPrompt(for userQuestion: String) -> Bool {
        let normalizedQuestion = userQuestion.lowercased()
        guard !normalizedQuestion.isEmpty else { return false }
        // 完全依赖 SKILL.md 的 triggers 字段，不再硬编任何领域关键词
        return !matchedSkillIds(for: userQuestion).isEmpty
    }

    /// 纯函数：根据已计算的条件变量确定 processInput 的路由路径。
    /// 可独立单元测试，也用于埋点日志。
    static func decideRoute(
        requiresMultimodal: Bool,
        shouldUsePlanner: Bool,
        shouldUseFullAgentPrompt: Bool
    ) -> String {
        if requiresMultimodal { return "vlm" }
        if shouldUsePlanner { return "planner" }
        if shouldUseFullAgentPrompt { return "agent" }
        return "light"
    }
}
