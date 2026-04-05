import Foundation

// MARK: - Prompt 构造器（Gemma 4 对话模板 + Function Calling）
//
// Gemma 4 使用新 token 格式：
//   <|turn>system\n ... <turn|>
//   <|turn>user\n ... <turn|>
//   <|turn>model\n ... <turn|>

struct PromptBuilder {

    static let defaultSystemPrompt = "你是 PhoneClaw，一个运行在本地的私人 AI 助手。你完全运行在设备上，不联网。"
    static let multimodalSystemPrompt = "你是 PhoneClaw，一个运行在本地设备上的视觉助手。请仅根据图片和用户问题作答，优先识别图中的主要物体、用途、场景和可读文本；如果看不清或不确定，请直接说明，不要编造。用简体中文回答。这是纯图文问答，不要调用任何工具或技能。"

    private static func imagePromptSuffix(count: Int) -> String {
        guard count > 0 else { return "" }
        return "\n" + Array(repeating: "<|image|>", count: count).joined(separator: "\n")
    }

    /// 构造完整 Prompt（包含工具定义 + 对话历史）
    static func build(
        userMessage: String,
        currentImageCount: Int = 0,
        tools: [SkillInfo],
        history: [ChatMessage] = [],
        systemPrompt: String? = nil,
        historyDepth: Int = 4          // 动态传入，根据当前内存 headroom 估算
    ) -> String {
        let isMultimodalTurn = currentImageCount > 0
        var prompt = "<|turn>system\n"

        // ★ 使用自定义 system prompt（如果有），否则用默认
        let basePrompt =
            isMultimodalTurn
            ? multimodalSystemPrompt
            : (systemPrompt ?? defaultSystemPrompt)

        // 构建 Skill 概要列表（只列名称 + 一句话描述，不暴露 Tool）
        var skillListText = ""
        for skill in tools {
            skillListText += "- **\(skill.name)**: \(skill.description)\n"
        }

        if isMultimodalTurn {
            prompt += basePrompt
        } else if basePrompt.contains("___SKILLS___") {
            // 处理 ___SKILLS___ 占位符
            prompt += basePrompt.replacingOccurrences(of: "___SKILLS___", with: skillListText)
        } else {
            // SYSPROMPT.md 不含 ___SKILLS___ 时的兜底：只追加技能列表，不追加指令。
            // 调用规则已在 SYSPROMPT.md 里定义，不在这里硬编。
            prompt += basePrompt
            if !tools.isEmpty {
                prompt += "\n\n你拥有以下能力（Skill）：\n\n" + skillListText
            }
        }

        prompt += "\n<turn|>\n"

        // 对话历史（动态深度，由 llm.safeHistoryDepth 控制）
        // E4B 内存限制：jetsam 上限 6144 MB，模型占用 4220 MB，仅剩 ~1.9 GB。
        // suffix(12) 在工具调用后会积累 6+ 条消息（tool_call + result × N），
        // 使 prefill 超过 1000 tokens，导致第二次提问时 OOM。
        // suffix(4) 保留最近 2 轮（≈200 tokens history），足够连贯对话。
        let recentHistory = history.suffix(historyDepth)
        for msg in recentHistory {
            // ★ 跳过最后一条 user 消息（等下面单独加）
            if msg.role == .user && msg.id == recentHistory.last?.id { continue }
            switch msg.role {
            case .user:
                // Current multimodal support is image-first and single-image-per-turn.
                // We keep historical image metadata in the UI, but only materialize
                // image placeholders for the current turn and its tool follow-ups.
                prompt += "<|turn>user\n\(msg.content)<turn|>\n"
            case .assistant:
                prompt += "<|turn>model\n\(msg.content)<turn|>\n"
            case .system:
                if let skillName = msg.skillName {
                    prompt += "<|turn>model\n<tool_call>\n{\"name\": \"\(skillName)\", \"arguments\": {}}\n</tool_call><turn|>\n"
                }
            case .skillResult:
                let skillLabel = msg.skillName ?? "tool"
                prompt += "<|turn>user\n工具 \(skillLabel) 的执行结果：\(msg.content)<turn|>\n"
            }
        }

        // 当前用户消息
        prompt += "<|turn>user\n\(userMessage)\(imagePromptSuffix(count: currentImageCount))<turn|>\n"
        prompt += "<|turn>model\n"

        return prompt
    }

    /// 构造工具/Skill 结果后的 follow-up prompt
    ///
    /// E4B 内存约束：follow-up 不能拼接完整 originalPrompt（会使 prefill 过长）。
    /// 改为构建一个独立的紧凑 prompt：保留 system context + 用户问题 + 工具结果。
    static func buildFollowUp(
        originalPrompt: String,
        modelResponse: String,
        skillName: String,
        skillResult: String,
        userQuestion: String,
        currentImageCount: Int = 0,
        isLoadSkill: Bool = false
    ) -> String {
        // Extract system block from originalPrompt to keep persona/skill list,
        // but don't carry forward the full multi-turn history.
        let systemBlock: String
        if let turnEnd = originalPrompt.range(of: "<turn|>\n") {
            systemBlock = String(originalPrompt[originalPrompt.startIndex...turnEnd.upperBound])
        } else {
            systemBlock = originalPrompt
        }

        var prompt = systemBlock

        // Include the triggering user question
        prompt += "<|turn>user\n\(userQuestion)\(imagePromptSuffix(count: currentImageCount))<turn|>\n"

        // Include the model's first response (the tool_call)
        var cleanedResponse = modelResponse
        for pat in ["<turn|>", "<end_of_turn>", "<eos>"] {
            cleanedResponse = cleanedResponse.replacingOccurrences(of: pat, with: "")
        }
        prompt += "<|turn>model\n\(cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines))<turn|>\n"

        if isLoadSkill {
            prompt += """
            <|turn>user
            Skill 指令已加载：
            \(skillResult)

            请根据以上指令，调用对应的工具来完成用户的请求："\(userQuestion)"
            如果用户的问题并不需要这个 skill，直接回答，不要强行调用工具。
            不要告诉用户"请使用某个能力"或"请打开某个 skill"，需要的话你自己直接调用工具。
            你的下一条回复必须是以下两种之一：
            1. 一个 `<tool_call>...</tool_call>`
            2. 直接给用户的最终回答
            不能输出空白。
            <turn|>
            <|turn>model

            """
        } else {
            prompt += """
            <|turn>user
            工具 \(skillName) 执行结果：
            \(skillResult)

            请根据以上结果直接回答我的问题："\(userQuestion)"
            如果结果已经足够，请直接给出最终答案，不要反问，不要重复工具调用。
            只有在结果明确不足以回答时，才简短说明还缺什么信息。
            不能输出空白；即使结果是 JSON，也要整理成一句或几句可读的最终回复。
            <turn|>
            <|turn>model

            """
        }
        return prompt
    }

    static func buildForcedSkillContinuation(
        priorPrompt: String,
        userQuestion: String
    ) -> String {
        priorPrompt + """
        <turn|>
        <|turn>user
        继续完成刚才的任务："\(userQuestion)"

        你已经加载了所需 skill。
        不要解释，不要重复，不要让用户自己去使用 skill。
        现在必须二选一：
        1. 立即输出一个 `<tool_call>...</tool_call>`
        2. 如果已经足够回答，直接输出最终答案
        不能输出空白。
        <turn|>
        <|turn>model

        """
    }
}
