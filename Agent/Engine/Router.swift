import Foundation

extension AgentEngine {

    // MARK: - 通用工具

    func uniqueStringsPreservingOrder(_ values: [String]) -> [String] {
        Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    /// trigger 词级匹配。
    ///
    /// 历史 bug: 之前用 `String.contains` 子串匹配, 导致 "prevents" 命中
    /// trigger "event" → Bitcoin 等知识问题误进 calendar agent 路径,
    /// 模型勉强 fire 一个 invalid load_skill 然后空回复.
    ///
    /// 修法分支:
    ///   - 纯 ASCII trigger (calendar 的 "event" / contacts 的 "phone" 等):
    ///     用 `\b…\b` Unicode 词边界正则. "prevents" 不会匹配 \bevent\b
    ///     因为 't' 'e' 都是 word char 之间没有 word boundary.
    ///   - 含 CJK trigger ("联系人"/"提醒"等): CJK 无词边界概念,
    ///     `\b` 在 CJK 之间不触发, 直接 substring 匹配.
    ///
    /// 这只动 Router 行为, 不改 SKILL.md trigger 内容, zh / en 都受益.
    func containsAsWord(_ trigger: String, in text: String) -> Bool {
        let isAsciiWord = !trigger.isEmpty && trigger.unicodeScalars.allSatisfy { scalar in
            // ASCII 字母数字 + 词内常见连接符 (-, _) 算 word char
            (scalar.value < 128) && (
                CharacterSet.alphanumerics.contains(scalar) ||
                scalar == "-" || scalar == "_"
            )
        }
        guard isAsciiWord else {
            // CJK / 混合 / 含空格的 trigger: 直接 substring
            return text.contains(trigger)
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text.contains(trigger)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
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

            var isMatch = lowercasedNames.contains { containsAsWord($0, in: normalizedQuestion) }
            if !isMatch,
               let definition = skillRegistry.getDefinition(skillId) {
                isMatch = definition.metadata.triggers.contains { trigger in
                    let normalizedTrigger = trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    return !normalizedTrigger.isEmpty && containsAsWord(normalizedTrigger, in: normalizedQuestion)
                } || definition.metadata.allowedTools.contains { toolName in
                    containsAsWord(toolName.lowercased(), in: normalizedQuestion)
                }
            }

            if isMatch {
                matched.append(skillId)
            }
        }

        // Sticky routing: 当前消息没命中任何 trigger, 但最近 history 里有
        // 活跃 skill 上下文 -> 继续使用该 skill。
        //
        // 框架对 E2B / E4B 完全一视同仁, 不做任何模型分支。如果小模型在某
        // 些多轮场景下表现不稳, 那是模型能力问题, 框架不偷偷修。默认前提
        // 是用户只装了一个模型, 装的是哪个就用哪个。
        if matched.isEmpty, let stickySkillId = recentActiveSkillId() {
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
    /// P1-1 源头修复: AgentEngine 只对 type: device 的 skill 打 eager tag,
    /// content skill (translate 等) 从源头不参与 sticky, 避免一问一答
    /// 纯变换后的闲聊被污染回 translate。
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
            // .assistant, .skillResult, .system 只要 skillName 非空就算锚点。
            // .assistant 的 tag 由 AgentEngine 在 eager 打 (device skill 才打)。
            // .skillResult 是 ToolChain 在 tool 成功后 append, 自带 tool 名, 可反查 skill。
            guard (msg.role == .skillResult || msg.role == .system || msg.role == .assistant),
                  let name = msg.skillName, !name.isEmpty else {
                continue
            }

            // name 可能是 skill id (如 "calendar") 或 tool name (如 "calendar-create-event")。
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
