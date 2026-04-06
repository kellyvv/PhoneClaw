import Foundation

// MARK: - Prompt 构造器（Gemma 4 对话模板 + Function Calling）
//
// Gemma 4 使用新 token 格式：
//   <|turn>system\n ... <turn|>
//   <|turn>user\n ... <turn|>
//   <|turn>model\n ... <turn|>

struct PromptBuilder {

    static let defaultSystemPrompt = "你是 PhoneClaw，一个运行在本地的私人 AI 助手。你完全运行在设备上，不联网。"
    private static let thinkingOpenMarker = "[[PHONECLAW_THINK]]"
    private static let thinkingCloseMarker = "[[/PHONECLAW_THINK]]"
    private static let thinkingLanguageInstruction = "如果启用了思考模式，思考通道和最终回答都必须使用简体中文，不要使用英文。"

    static func multimodalSystemPrompt(hasImages: Bool, hasAudio: Bool, enableThinking: Bool = false) -> String {
        let base: String
        if hasAudio && !hasImages {
            base = "你是 PhoneClaw，一个运行在本地设备上的音频助手。请把用户提供的音频视为需要分析的素材，而不是用户此刻正在对你说的话。请根据音频和文本任务直接作答，不要擅自改写用户任务，也不要额外追加不存在的意图。听不清或不确定时请明确说明，不要编造。如果用户是在询问音频里说了什么，或明确要求转写、识别、逐字写出，请直接给出识别结果，不要复述用户问题，不要寒暄。如果用户明确要求逐字转写，尽量保留原话，不要改写、总结、润色，也不要把音频内容当成需要你回应的对话。用简体中文回答。这是纯音频问答，不要调用任何工具或技能。"
        } else if hasImages && hasAudio {
            base = "你是 PhoneClaw，一个运行在本地设备上的多模态助手。请把用户提供的音频视为需要分析的素材，而不是用户此刻正在对你说的话。请根据用户提供的图片、音频和文本直接作答，不要擅自改写用户任务，也不要额外追加不存在的意图。看不清、听不清或不确定时请直接说明，不要编造。如果用户是在询问音频里说了什么，或明确要求转写、识别、逐字写出，请直接给出识别结果，不要复述用户问题，不要寒暄。如果用户明确要求逐字转写，尽量保留原话，不要改写、总结、润色，也不要把音频内容当成需要你回应的对话。用简体中文回答。这是纯多模态问答，不要调用任何工具或技能。"
        } else {
            base = "你是 PhoneClaw，一个运行在本地设备上的视觉助手。请仅根据图片和用户问题直接作答，并严格遵守以下规则：1. 默认先直接给结论，控制在1到2句内；2. 除非用户明确要求详细说明，否则禁止分点、禁止长篇分析、禁止列举多种可能性；3. 不要写“根据您提供的图片”“从画面中可以看到”等铺垫；4. 如果看不清或不确定，只需简短说明“看不清，像……”，不要编造。优先识别图中的主要物体、用途、场景和可读文本。用简体中文回答。这是纯图文问答，不要调用任何工具或技能。"
        }

        return enableThinking ? base + "\n" + thinkingLanguageInstruction : base
    }

    private static func imagePromptSuffix(count: Int) -> String {
        guard count > 0 else { return "" }
        return "\n" + Array(repeating: "<|image|>", count: count).joined(separator: "\n")
    }

    private static func extractSystemBlock(from prompt: String) -> String {
        if let turnEnd = prompt.range(of: "<turn|>\n") {
            return String(prompt[prompt.startIndex...turnEnd.upperBound])
        }
        return prompt
    }

    private static func injectIntoSystemBlock(
        _ systemBlock: String,
        extraInstructions: String
    ) -> String {
        let trimmedExtra = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExtra.isEmpty else { return systemBlock }

        guard let turnEnd = systemBlock.range(of: "<turn|>\n", options: .backwards) else {
            return systemBlock + "\n\n" + trimmedExtra + "\n<turn|>\n"
        }

        let head = systemBlock[..<turnEnd.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "\n\n" + trimmedExtra + "\n<turn|>\n"
    }

    private static func sanitizedAssistantHistoryContent(_ text: String) -> String {
        var result = text

        while let openRange = result.range(of: thinkingOpenMarker) {
            if let closeRange = result.range(of: thinkingCloseMarker, range: openRange.upperBound..<result.endIndex) {
                result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                result.removeSubrange(openRange.lowerBound..<result.endIndex)
                break
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lightweightTextSystemPrompt(systemPrompt: String?) -> String {
        let rawBase = (systemPrompt ?? defaultSystemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstParagraph = rawBase
            .components(separatedBy: "\n\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let base = (firstParagraph?.isEmpty == false ? firstParagraph! : defaultSystemPrompt)
        return base + "\n\n当前这轮只是普通文字对话，不需要调用任何设备技能或工具。请直接回答用户，避免提到 Skill、load_skill、tool_call 或设备操作流程。用简体中文回答，默认简洁。"
    }

    /// 构造完整 Prompt（包含工具定义 + 对话历史）
    static func build(
        userMessage: String,
        currentImageCount: Int = 0,
        tools: [SkillInfo],
        history: [ChatMessage] = [],
        systemPrompt: String? = nil,
        enableThinking: Bool = false,
        historyDepth: Int = 4          // 动态传入，根据当前内存 headroom 估算
    ) -> String {
        let isMultimodalTurn = currentImageCount > 0
        var prompt = "<|turn>system\n"
        if enableThinking {
            prompt += "<|think|>"
        }

        // ★ 使用自定义 system prompt（如果有），否则用默认
        let basePrompt =
            isMultimodalTurn
            ? multimodalSystemPrompt(hasImages: currentImageCount > 0, hasAudio: false, enableThinking: enableThinking)
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

        if enableThinking && !isMultimodalTurn {
            prompt += "\n\n" + thinkingLanguageInstruction
        }

        prompt += "\n<turn|>\n"

        // 对话历史（动态深度，由 llm.safeHistoryDepth 控制）
        // E2B 内存限制：jetsam 上限 6144 MB，模型占用 4220 MB，仅剩 ~1.9 GB。
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
                let assistantContent = sanitizedAssistantHistoryContent(msg.content)
                prompt += "<|turn>model\n\(assistantContent)<turn|>\n"
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

    static func buildLightweightTextPrompt(
        userMessage: String,
        history: [ChatMessage] = [],
        systemPrompt: String? = nil,
        enableThinking: Bool = false,
        historyDepth: Int = 2
    ) -> String {
        var prompt = "<|turn>system\n"
        if enableThinking {
            prompt += "<|think|>"
        }
        prompt += lightweightTextSystemPrompt(systemPrompt: systemPrompt)
        if enableThinking {
            prompt += "\n\n" + thinkingLanguageInstruction
        }
        prompt += "\n<turn|>\n"

        let recentHistory = history.suffix(historyDepth)
        for msg in recentHistory {
            if msg.role == .user && msg.id == recentHistory.last?.id { continue }
            switch msg.role {
            case .user:
                prompt += "<|turn>user\n\(msg.content)<turn|>\n"
            case .assistant:
                let assistantContent = sanitizedAssistantHistoryContent(msg.content)
                guard !assistantContent.isEmpty else { continue }
                prompt += "<|turn>model\n\(assistantContent)<turn|>\n"
            case .system, .skillResult:
                continue
            }
        }

        prompt += "<|turn>user\n\(userMessage)<turn|>\n"
        prompt += "<|turn>model\n"
        return prompt
    }

    /// `load_skill` 之后重新推理：
    /// 直接把已加载的 Skill 指令注入 system turn，再重新回答原问题。
    /// 这样比“把 tool_call + skill body + retry 指令继续拼接”更稳定，也更省 prefill。
    static func buildLoadedSkillPrompt(
        originalPrompt: String,
        userQuestion: String,
        skillInstructions: String,
        currentImageCount: Int = 0,
        forceResponse: Bool = false
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)
        let systemInstructions = injectIntoSystemBlock(
            systemBlock,
            extraInstructions: """
            对于当前这一个用户问题，你已经加载了所需的 Skill 指令。
            不要再次调用 `load_skill`。
            如果需要执行设备内操作，直接调用对应工具；如果不需要工具，直接回答。

            已加载的 Skill 指令：
            \(skillInstructions)
            """
        )

        var prompt = systemInstructions
        prompt += """
        <|turn>user
        用户问题：
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

        处理这个请求时，严格按以下顺序执行：
        1. 使用已经加载的 Skill 指令，不要再次调用 `load_skill`。
        2. 如果需要设备内操作，直接调用对应工具。
        3. 如果工具已经成功返回，或者已经足够回答，就只输出最终结果。

        不要让用户去“打开 skill”或“使用某个能力”，需要的话你自己直接调用工具。
        你必须避免输出任何中间思考、状态更新、字段名、JSON 模板、代码块或规划草稿。
        \(forceResponse
          ? "你的下一条回复必须是以下两种之一：1. 一个 `<tool_call>...</tool_call>` 2. 直接给用户的最终回答正文。禁止输出空白。"
          : "如果需要工具就直接调用；如果已经足够回答，就直接给出最终答案正文。")
        <turn|>
        <|turn>model

        """
        return prompt
    }

    /// 工具执行完成后，重新构造一个最小回答 prompt，避免把上一轮 tool_call
    /// 和完整历史继续累积到 follow-up 中。
    static func buildToolAnswerPrompt(
        originalPrompt: String,
        toolName: String,
        toolResultSummary: String,
        userQuestion: String,
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)

        return systemBlock + """
        <|turn>user
        用户原始问题：
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

        工具 \(toolName) 已执行完成。
        可直接给用户的结果：
        \(toolResultSummary)

        请基于以上结果直接回答用户。
        如果上面的内容已经是完整答案，你可以只做最少整理，但不要遗漏关键信息。
        不要重复调用工具，不要反问，不要提到工具名、Skill、status、result、arguments 等字段。
        不要输出 Markdown 代码块，也不要输出 JSON、键名、模板或中间步骤。
        不能输出空白。
        <turn|>
        <|turn>model

        """
    }

    /// 单 Skill + 单工具时，先只让模型抽取 arguments，避免它直接续写出半截
    /// `<tool_call>` 或字段草稿。
    static func buildSingleToolArgumentsPrompt(
        originalPrompt: String,
        userQuestion: String,
        skillInstructions: String,
        toolName: String,
        toolParameters: String,
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)
        let systemInstructions = injectIntoSystemBlock(
            systemBlock,
            extraInstructions: """
            对于当前这一个用户问题，你已经加载了所需的 Skill 指令。
            不要再次调用 `load_skill`。

            已加载的 Skill 指令：
            \(skillInstructions)
            """
        )

        return systemInstructions + """
        <|turn>user
        用户问题：
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

        你现在只负责为工具 `\(toolName)` 提取 arguments。
        工具参数说明：
        \(toolParameters)

        严格遵守以下要求：
        1. 不要调用工具，不要输出 `<tool_call>`。
        2. 只输出一个 JSON object，内容就是 arguments 本身。
        3. 不要输出 Markdown、代码块、解释、字段草稿或多余文字。
        4. 可选字段如果没有，就直接省略。
        5. 时间字段必须转换成 ISO 8601，例如 `2026-04-07T20:00:00`。
        6. 如果缺少必填参数，输出：
           {"_needs_clarification":"请补充缺少的信息"}
        <turn|>
        <|turn>model

        """
    }

    /// 单 Skill + 多工具时，让模型只在允许的工具集合中选择一个工具并抽取 arguments。
    static func buildSkillToolSelectionPrompt(
        originalPrompt: String,
        userQuestion: String,
        skillInstructions: String,
        allowedToolsSummary: String,
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)
        let systemInstructions = injectIntoSystemBlock(
            systemBlock,
            extraInstructions: """
            对于当前这一个用户问题，你已经加载了所需的 Skill 指令。
            不要再次调用 `load_skill`。

            已加载的 Skill 指令：
            \(skillInstructions)
            """
        )

        return systemInstructions + """
        <|turn>user
        用户问题：
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

        你现在只负责两件事：
        1. 在下面允许的工具里选择最合适的一个
        2. 为该工具提取 arguments

        允许的工具：
        \(allowedToolsSummary)

        严格遵守以下要求：
        1. 不要调用工具，不要输出 `<tool_call>`。
        2. 只输出一个 JSON object，格式必须是：
           {"name":"工具名","arguments":{"参数名":"参数值"}}
        3. `name` 必须是上面允许的工具之一。
        4. `arguments` 里只保留当前工具需要的参数；没有的可选参数直接省略。
        5. 不要输出 Markdown、代码块、解释、草稿或多余文字。
        6. 时间字段必须转换成 ISO 8601，例如 `2026-04-07T20:00:00`。
        7. 如果缺少执行所需的关键信息，输出：
           {"_needs_clarification":"请补充缺少的信息"}
        <turn|>
        <|turn>model

        """
    }
}
