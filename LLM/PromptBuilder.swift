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

    // internal (not private): 被 LLM/LiveVoice/PromptBuilder+LiveVoice.swift 复用
    static func imagePromptSuffix(count: Int) -> String {
        guard count > 0 else { return "" }
        return "\n" + Array(repeating: "<|image|>", count: count).joined(separator: "\n")
    }

    /// 工具参数提取阶段需要的"当前时间锚点"。
    /// 模型必须知道"现在是何时"才能解析"明天/下午两点"等相对时间表达
    /// 并写出正确的 ISO 8601 字符串。
    /// 用本地时区(用户设备时区), 周几用中文,方便中文模型理解。
    private static func currentTimeAnchorBlock() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let now = formatter.string(from: Date())
        return "当前时间锚点(用于解析\"今天/明天/下午两点\"等相对时间): \(now)"
    }

    private static func extractSystemBlock(from prompt: String) -> String {
        let raw: String
        if let turnEnd = prompt.range(of: "<turn|>\n") {
            raw = String(prompt[prompt.startIndex...turnEnd.upperBound])
        } else {
            raw = prompt
        }
        // 在 secondary prompt 的 system block 末尾追加"当前时间锚点"。
        // 这是 runtime data injection,不感知任何业务:任何调用 extractSystemBlock
        // 的 prompt builder(load_skill 之后、tool answer、planner 各阶段等)
        // 自动获得"现在是何时"的上下文,模型才能解析"明天/下午两点"等
        // 相对时间表达。
        return injectIntoSystemBlock(raw, extraInstructions: currentTimeAnchorBlock())
    }

    /// 从一个完整 prompt(由 PromptBuilder.build() 构造)里提取
    /// "system 块结束之后, 当前 user 消息开始之前"的所有历史 turn 块。
    ///
    /// 用途: secondary 推理(load_skill 之后、tool 执行之后、planner 各阶段)
    /// 自动获得和 first inference 同样的对话历史, 不再是无记忆地只看当前消息。
    ///
    /// 实现是纯字符串切片, 不感知任何业务: 切的是 PromptBuilder.build() 自己
    /// 渲染的 turn 标签结构, 任何 secondary prompt builder 都能受益。
    private static func extractHistoryBlock(from prompt: String) -> String {
        guard let systemEnd = prompt.range(of: "<turn|>\n") else { return "" }
        let afterSystem = systemEnd.upperBound

        // 找最后一个 "<|turn>user\n" - 那是当前 user message 的开头
        let searchRange = afterSystem..<prompt.endIndex
        guard let lastUserStart = prompt.range(
            of: "<|turn>user\n",
            options: .backwards,
            range: searchRange
        ) else {
            return ""
        }

        // 返回 system 结束 ~ 当前 user 开始 之间的所有历史 turn
        return String(prompt[afterSystem..<lastUserStart.lowerBound])
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

    // internal (not private): 被 LLM/LiveVoice/PromptBuilder+LiveVoice.swift 复用
    static func sanitizedAssistantHistoryContent(_ text: String) -> String {
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
        // 策略: 完整暴露 SYSPROMPT + 强关闭 tool_call 指令尾缀.
        //
        // 历史: 曾经只取第一段防 Skill 规则污染 light 路径. 但 CLI harness 实测
        // (2026-04-16, E2B/E4B × "你是谁"/"翻译"/"删联系人"/"总结"/"天气" 矩阵) 证明:
        //   1. 全暴露后 Gemma 不会在 light 路径发 <tool_call> (尾缀"严禁输出"
        //      压制成功, 即使 prompt 里带 <tool_call> 例子也不会自发模仿)
        //   2. E2B 在"你是谁"场景 persona 显著改善 (能说出 PhoneClaw)
        //   3. E2B 在"删联系人"场景修掉致命幻觉 —— 只取第一段时 E2B 会回
        //      "好的，我已经将联系人张三删除了" 假装执行, 全暴露后正确询问
        //
        // 代价: E4B × "翻译" 场景会在答首加一句 "我是 Gemma 4..." 自爆身份.
        // 这是可接受的 trade-off (safety > persona style), 可通过在 SYSPROMPT.md
        // 第一段加 "禁止自称 Gemma" 进一步缓解.
        let rawBase = (systemPrompt ?? defaultSystemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        return rawBase + "\n\n【当前模式: 闲聊】本轮严禁输出 <tool_call>, 严禁提及 Skill / load_skill / 工具调用. 上文所有 Skill 调用规则本轮一律不适用. 用简体中文直接回答, 默认简洁."
    }

    /// Preloaded skill block — Router 已经确定性匹配到 skill 时直接带它们的 body
    /// 进第一轮 prompt, 跳过 load_skill 往返。小模型(E2B/E4B)在多轮工具调用
    /// 上的成功率由此大幅提升。
    struct PreloadedSkill {
        let id: String
        let displayName: String
        let body: String
        let allowedTools: [String]
    }

    /// 构造完整 Prompt（包含工具定义 + 对话历史）
    static func build(
        userMessage: String,
        currentImageCount: Int = 0,
        tools: [SkillInfo],
        history: [ChatMessage] = [],
        systemPrompt: String? = nil,
        enableThinking: Bool = false,
        historyDepth: Int = 4,          // 动态传入，根据当前内存 headroom 估算
        showListSkillsHint: Bool = false, // 仅全量注入时为 true，提示模型可查询更多能力
        preloadedSkills: [PreloadedSkill] = [] // Router 已锁定的 skill, 直接 inline body
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
        // 按 SkillType 分两组, 给模型不同调用规则。
        let deviceSkills = tools.filter { $0.type == .device }
        let contentSkills = tools.filter { $0.type == .content }
        func renderList(_ list: [SkillInfo]) -> String {
            if list.isEmpty { return "（无）\n" }
            return list.map { "- **\($0.name)**: \($0.description)" }.joined(separator: "\n") + "\n"
        }
        let deviceListText = renderList(deviceSkills)
        let contentListText = renderList(contentSkills)
        // 兼容旧版 SYSPROMPT.md (仅 ___SKILLS___) 的扁平列表
        let flatListText: String = {
            var s = ""
            for skill in tools { s += "- **\(skill.name)**: \(skill.description)\n" }
            return s
        }()

        if isMultimodalTurn {
            prompt += basePrompt
        } else if basePrompt.contains("___DEVICE_SKILLS___") || basePrompt.contains("___CONTENT_SKILLS___") {
            // 新版双占位符: 按类别分别注入
            var resolved = basePrompt
            resolved = resolved.replacingOccurrences(of: "___DEVICE_SKILLS___", with: deviceListText)
            resolved = resolved.replacingOccurrences(of: "___CONTENT_SKILLS___", with: contentListText)
            prompt += resolved
        } else if basePrompt.contains("___SKILLS___") {
            // 旧版扁平占位符: 保留向后兼容
            prompt += basePrompt.replacingOccurrences(of: "___SKILLS___", with: flatListText)
        } else {
            // SYSPROMPT.md 不含任何占位符时的兜底：只追加技能列表，不追加指令。
            prompt += basePrompt
            if !tools.isEmpty {
                prompt += "\n\n你拥有以下能力（Skill）：\n\n" + flatListText
            }
        }

        // 仅全量注入（无匹配命中）时，提示模型可通过 list_skills 发现更多能力
        if showListSkillsHint && !isMultimodalTurn {
            prompt += "\n如果以上列出的能力都不匹配用户需求，可以调用 list_skills 查询更多能力：\n<tool_call>\n{\"name\": \"list_skills\", \"arguments\": {\"query\": \"用户需求描述\"}}\n</tool_call>\n"
        }

        // Router 已匹配的 skill: 直接 inline 它的 body + 工具白名单, 跳过 load_skill 往返。
        // 小模型做 "要不要 load_skill" 的 judgment call 非常不稳定; Router 既然已经
        // 基于 trigger 确定性地匹配到了, 就别再让模型犹豫一次。
        //
        // Note: skill body 必须留在 system turn 内。实验 (WS4) 证明移到 user turn
        // 会导致模型不遵循 SKILL.md 的回复规则 (三档解读丢失、tool call 不触发)。
        // 跨 skill KV cache 加速 (~175ms) 不值得牺牲指令遵循质量。
        if !preloadedSkills.isEmpty && !isMultimodalTurn {
            let allAllowed = Array(Set(preloadedSkills.flatMap(\.allowedTools))).sorted()
            prompt += "\n\n━━━━━━━━━━━━━━━━━━━━\n"
            prompt += "【已锁定能力 — 直接调用工具, 不需要先 load_skill】\n"
            if allAllowed.isEmpty {
                prompt += "当前锁定的 Skill 没有工具, 按 Skill 指令直接给最终答案, 禁止输出 <tool_call>。\n"
            } else {
                prompt += "\n可调用的工具 (只允许这些名字, 其他名字一律视为非法, 不要凭空编造):\n"
                prompt += allAllowed.map { "- `\($0)`" }.joined(separator: "\n") + "\n"
                prompt += "\n如果需要操作, 输出:\n<tool_call>\n{\"name\": \"<上面列表中的名字>\", \"arguments\": {...}}\n</tool_call>\n"
                prompt += "如果不需要工具就直接给最终答案正文。**不要**再调用 load_skill, 已经加载好了。\n"
            }
            for sk in preloadedSkills {
                prompt += "\n━━ Skill: \(sk.displayName) ━━\n"
                prompt += sk.body + "\n"
            }
            prompt += "━━━━━━━━━━━━━━━━━━━━\n"
        }

        if enableThinking && !isMultimodalTurn {
            prompt += "\n\n" + thinkingLanguageInstruction
        }

        // 时间锚点 — 必须在 system block 内, 模型才能算 "明天下午两点" → ISO 8601.
        // 历史: 2026-04-17 真机日历创建 bug 根因. SKILL.md 里有 "结合 system prompt
        // 的当前时间锚点算出 ISO 8601" 这种指令, 但 round 1 prompt 一直没注入锚点
        // (只有 secondary prompt 走 extractSystemBlock 时才注入). 结果 E4B 瞎编日期
        // (2026-04-08 而非"明天"), E2B 直接输出中文字面 "明天下午2:00" 让 tool 解析
        // 失败. harness agent-e2e 复现+证实. multimodal turn 不带 (那条路径不走 SKILL).
        if !isMultimodalTurn {
            prompt += "\n\n" + currentTimeAnchorBlock()
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
        availableTools: [String],
        currentImageCount: Int = 0,
        forceResponse: Bool = false
    ) -> String {
        // Scaffold (T2 progressive disclosure):
        // 显式告诉模型当前 skill 有哪些工具可调 (只列名字, 不列 schema —
        // schema 属于 T3 暴露)。空列表时明确说"无工具", 防止模型幻觉编造
        // 不存在的工具名 (例如 "professional_translator")。
        let toolBlock: String
        if availableTools.isEmpty {
            toolBlock = """
            当前 Skill **没有任何可调用的工具**。
            按 Skill 指令直接给最终答案正文文本, 禁止输出 <tool_call>。
            """
        } else {
            let listText = availableTools.map { "- `\($0)`" }.joined(separator: "\n")
            toolBlock = """
            当前 Skill 可调用的工具 (只允许这些名字):
            \(listText)
            如果需要操作, 输出 <tool_call>{"name": "<上面列表中的名字>", "arguments": {...}}</tool_call>。
            其他名字一律视为非法, 不要凭空编造。
            如果不需要工具, 直接给最终答案正文文本。
            """
        }

        let systemBlock = extractSystemBlock(from: originalPrompt)
        let systemInstructions = injectIntoSystemBlock(
            systemBlock,
            extraInstructions: """
            对于当前这一个用户问题, 你已经加载了所需的 Skill 指令。不要再次调用 `load_skill`。

            已加载的 Skill 指令:
            \(skillInstructions)

            \(toolBlock)
            """
        )

        var prompt = systemInstructions
        prompt += extractHistoryBlock(from: originalPrompt)
        prompt += """
        <|turn>user
        用户问题:
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

        按上面的 Skill 指令处理这个请求。
        - 不要再次调用 load_skill。
        - 不要让用户去"打开 skill"或"使用某个能力"。
        - 不要输出中间思考/状态更新/字段名/JSON 模板/代码块/规划草稿。
        \(forceResponse
          ? "你必须输出非空内容: 要么是合法的 <tool_call>...</tool_call>, 要么是最终答案正文。"
          : "如果不需要工具就直接给最终答案正文; 如果需要工具按上面规定的工具名调用。")
        <turn|>
        <|turn>model

        """
        return prompt
    }

    /// **F3 (2026-04-17)**: R2 prompt = R1 cached prompt + R1 model output + tool_result message.
    /// 物理上是同一个 conversation 的延伸 (跟 Anthropic/OpenAI tool_use 协议一致),
    /// 不再重新构造 R2 system block. KV cache 自然 reuse R1 全部 token, 只 prefill
    /// 末尾几十 token 的 tool_result message — 跨 R1/R2 命中率从 6% → 99%+.
    ///
    /// E2B 5-round repeat 防御机制: tool_result message 内嵌**极强 anti-repeat 指令**,
    /// 同时利用模型见过的 tool_use 训练格式 (assistant tool_call → tool_result → assistant text)
    /// 自然引导模型生成文本 (而非再 emit tool_call).
    ///
    /// `r1Output` 必须包含 R1 generated 的完整文本 (含 <tool_call> 标签). caller
    /// 不应清洗 — 物理上模型在 R2 看到自己刚说过什么, 才能正确续写.
    static func appendToolResult(
        toR1Prompt r1Prompt: String,
        r1Output: String,
        toolName: String,
        toolResultSummary: String
    ) -> String {
        // R1 prompt 末尾是 "<|turn>model\n" — caller 已经 emit r1Output 之后, 我们
        // 补 turn 关闭 + tool_result user turn + 新的 model turn 起手.
        //
        // Prompt 设计**极简** (Anthropic tool_use 风格): 模型见过这种训练格式
        // (assistant tool_call → user tool_result → assistant text), 自然知道接下来
        // 该用文本回答. 长 anti-repeat / "严禁 X / 不要 Y / 不能 Z" 指令链实测让 E2B
        // 直接 emit EOS (0 token 空回复, 真机验证).
        return r1Prompt + r1Output + """
        <turn|>
        <|turn>user
        \(toolResultSummary)
        <turn|>
        <|turn>model

        """
    }

    /// 工具执行完成后, 构造 follow-up prompt 让模型用 tool_result 回答用户.
    ///
    /// **历史 / 设计权衡 (2026-04-17 数据驱动决策)**:
    /// - 试 1 (lean R2 system): 修了 E2B 5-round repeat tool_call, 但 system block
    ///   跟 R1 不一致 → KV cache 跨 R1/R2 几乎全 miss (common=17 token), 真机 E4B
    ///   长 prompt 闪崩 (delta=2021 token 重算).
    /// - 试 2 (full R2 system + 强 anti-repeat): KV 命中率回升到 78-95%, E4B 不崩.
    ///   但 E2B 被 system 里的 SKILL body "理想流程模板" 带跑, tool 真返失败时
    ///   E2B 反而幻觉成功 (例: contacts 多人匹配, tool 返"匹配多个", E2B 答"已删除").
    ///   E2B conversation 13/18 → 11/18.
    ///
    /// 当前选 lean R2 — 优先 E2B 准确性 (用户实际部署模型). KV 命中率优化作为
    /// 后续框架级 refactor (移 SKILL body 到 user turn 解决根本性的 R1/R2 system
    /// block 冲突). 真机 E4B 闪崩的根因 (KV cache miss → 长 delta) 改用 R2 不
    /// 污染 R1 cache 的方案缓解 (TODO: cache snapshot/restore around R2).
    static func buildToolAnswerPrompt(
        originalPrompt: String,
        toolName: String,
        toolResultSummary: String,
        userQuestion: String,
        currentImageCount: Int = 0
    ) -> String {
        let leanSystemBlock = """
        <|turn>system
        \(defaultSystemPrompt) 用中文回答, 简洁实用.
        \(currentTimeAnchorBlock())
        <turn|>

        """

        return leanSystemBlock + extractHistoryBlock(from: originalPrompt) + """
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

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + """
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
        6. 如果缺少必填参数,只输出一个 JSON object: {"_needs_clarification": "..."}。
           "..." 部分必须用一句完整中文,直接陈述当前请求缺哪个具体参数,
           不能含尖括号、不能含占位符、不能复制本规则的任何字面文本。
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

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + """
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
        7. 如果缺少执行所需的关键信息,只输出一个 JSON object: {"_needs_clarification": "..."}。
           "..." 部分必须用一句完整中文,直接陈述当前请求缺哪个具体信息,
           不能含尖括号、不能含占位符、不能复制本规则的任何字面文本。
        <turn|>
        <|turn>model

        """
    }

    // MARK: - Planner v3 Prompt Builders

    static func buildSkillSelectionPrompt(
        originalPrompt: String,
        userQuestion: String,
        availableSkillsSummary: String,
        recentContextSummary: String = "",
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)
        let systemInstructions = injectIntoSystemBlock(
            systemBlock,
            extraInstructions: """
            对于当前这一个用户问题，你现在只负责判断需要哪些 Skill。
            不要调用 `load_skill`，不要输出 `<tool_call>`，不要直接回答用户问题。

            可用的 Skill 与工具如下：
            \(availableSkillsSummary)
            """
        )

        let recentContextBlock: String
        if recentContextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recentContextBlock = ""
        } else {
            recentContextBlock = """

            最近已知的工具结果摘要（可作为当前规划的上下文）：
            \(recentContextSummary)
            """
        }

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + """
        <|turn>user
        用户问题：
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))\(recentContextBlock)

        请输出一个 JSON object，格式必须是：
        {
          "required_skills": ["skill_id_1", "skill_id_2"],
          "needs_clarification": null
        }

        严格遵守以下要求:
        1. 只输出 JSON object,不要输出 Markdown、代码块、解释或多余文字。
        2. `required_skills` 里的每一项必须严格等于上面"可用的 Skill 与工具"段落中列出的 skill id 字符串本身,不能填该 skill 下属的工具名,不能自己拼接,不能翻译。
        3. 如果任务需要先获取一个结果、再交给另一个 Skill 继续处理,涉及到的所有 Skill 都要列出来,不要只写最终那一个。
        4. 如果"最近已知的工具结果摘要"已经提供了部分信息,也要据此补全后续需要的 Skill,不要漏掉。
        5. 如果用户需求不需要任何 Skill,返回空数组 `[]`。
        6. 如果无法判断需要哪些 Skill,返回:
           {"required_skills": [], "needs_clarification": "请说明具体需要什么帮助"}
        <turn|>
        <|turn>model

        """
    }

    static func buildSkillPlanningPrompt(
        originalPrompt: String,
        userQuestion: String,
        availableSkillsSummary: String,
        recentContextSummary: String = "",
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)
        let systemInstructions = injectIntoSystemBlock(
            systemBlock,
            extraInstructions: """
            对于当前这一个用户问题，你现在只负责生成完整的执行计划。
            不要调用 `load_skill`，不要输出 `<tool_call>`，不要直接回答用户问题。

            本阶段只允许使用以下已选中的 Skill 与工具：
            \(availableSkillsSummary)
            """
        )

        let recentContextBlock: String
        if recentContextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recentContextBlock = ""
        } else {
            recentContextBlock = """

            最近已知的工具结果摘要（可作为当前规划的上下文）：
            \(recentContextSummary)
            """
        }

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + """
        <|turn>user
        用户问题：
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))\(recentContextBlock)

        请输出一个 JSON object，格式必须是：
        {
          "goal": "一句话目标",
          "steps": [
            {
              "id": "s1",
              "skill": "skill_id",
              "tool": "tool-name",
              "intent": "这一步要做什么",
              "depends_on": []
            }
          ],
          "needs_clarification": null
        }

        严格遵守以下要求：
        1. 只输出 JSON object，不要输出 Markdown、代码块、解释或多余文字。
        2. `skill` 必须是上面给出的 skill id 之一，`tool` 必须是该 skill 允许的工具之一，使用完整工具名。
        3. step 最多 4 步，按执行顺序排列。每个已选 skill 至少规划一步。
        4. `depends_on` 里只能引用前面步骤的 id。如果后续步骤需要前面步骤的结果，必须填写依赖。
        5. 如果不需要任何技能或工具，返回 `steps: []`。
        6. 如果后续步骤需要的信息可以通过前置步骤获得，或者已经出现在"最近已知的工具结果摘要"里，仍然要先把这些步骤规划出来，不要提前提问。
        7. 只要 `steps` 里还能放入至少一个可执行步骤，`needs_clarification` 就必须是 null。
        8. 只有在没有任何可行步骤可以获得关键缺失信息时，才返回：
           {"goal":"", "steps": [], "needs_clarification": "请说明具体需要什么"}
        <turn|>
        <|turn>model

        """
    }

    static func buildPlannedToolArgumentsPrompt(
        originalPrompt: String,
        userQuestion: String,
        stepIntent: String,
        toolName: String,
        toolParameters: String,
        completedStepSummary: String = "",
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)
        let systemInstructions = injectIntoSystemBlock(
            systemBlock,
            extraInstructions: """
            对于当前这一个用户问题，你现在只负责为工具提取参数。
            不要调用 `load_skill`，不要输出 `<tool_call>`，不要直接回答用户问题。
            """
        )

        let completedBlock: String
        if completedStepSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completedBlock = ""
        } else {
            completedBlock = "已完成步骤摘要：\n\(completedStepSummary)"
        }

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + """
        <|turn>user
        用户问题：
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

        当前步骤目标：
        \(stepIntent)

        \(completedBlock)

        你现在只负责为工具 `\(toolName)` 提取 arguments。
        工具参数说明：
        \(toolParameters)

        严格遵守以下要求：
        1. 不要调用工具，不要输出 `<tool_call>`。
        2. 只输出一个 JSON object，内容就是 arguments 本身。
        3. 不要输出 Markdown、代码块、解释、字段草稿或多余文字。
        4. 可选字段如果没有，就直接省略。
        5. 如果上面的已完成步骤里已经包含当前工具需要的信息，可以直接引用那些结果来补齐参数。
        6. 时间字段必须转换成 ISO 8601，例如 `2026-04-07T20:00:00`。
        7. 如果缺少必填参数,只输出一个 JSON object: {"_needs_clarification": "..."}。
           "..." 部分必须用一句完整中文,直接陈述当前步骤缺哪个具体参数,
           不能含尖括号、不能含占位符、不能复制本规则的任何字面文本。
        <turn|>
        <|turn>model

        """
    }

    /// Planner v3 chained 任务里执行 **content-type SKILL** 一步 (例如 translate).
    /// content SKILL 没 tool 可调, 模型按 SKILL.md 指令直接生成文本结果. 该结果
    /// 既作为 R2 给用户看, 也作为后续 step 的 prior result.
    ///
    /// Prompt 结构: 复用 R1 system block (含 SKILL list, 但不复用 SKILL body
    /// 因为我们这里显式给) + history + user turn 含: SKILL body + 完成步骤摘要 +
    /// 当前 step intent + 用户原问.
    static func buildContentStepPrompt(
        originalPrompt: String,
        userQuestion: String,
        skillInstructions: String,
        stepIntent: String,
        completedStepSummary: String = "",
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)

        // 关键: prior step 结果用三引号包裹明确隔离, 让 SKILL (例如 translate) 按
        // 自己规则准确识别"源文本". 之前 prior result 跟 user 原问题混在一起,
        // model 错把 user 原话当源文本翻译了 — 真机 E4B "读剪贴板, 翻译成英文"
        // 输出 "Read clipboard, translate to English." 复述用户原话, 没翻译剪贴板内容.
        let priorResultBlock: String
        if completedStepSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            priorResultBlock = ""
        } else {
            priorResultBlock = """

                上游步骤的输出 (这是本步的输入数据):
                \"\"\"
                \(completedStepSummary)
                \"\"\"

                """
        }

        return systemBlock + extractHistoryBlock(from: originalPrompt) + """
        <|turn>user
        本步目标 (Skill 任务): \(stepIntent)
        \(priorResultBlock)
        按下面 Skill 指令处理上述输入数据 (这一步没有 tool 可调, 直接输出最终文本结果):

        \(skillInstructions)

        重要:
        - 输入数据是上面三引号里的内容, 不是用户原问.
        - 直接输出最终文本结果, 不复述输入, 不解释过程.
        - 不要 emit `<tool_call>`, 不要 Markdown 代码块.
        <turn|>
        <|turn>model

        """
    }

    static func buildMultiToolAnswerPrompt(
        originalPrompt: String,
        toolResults: [(toolName: String, result: String)],
        userQuestion: String,
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)
        var resultsBlock = ""
        for (toolName, result) in toolResults {
            resultsBlock += "工具 \(toolName) 的执行结果：\(result)\n"
        }

        return systemBlock + extractHistoryBlock(from: originalPrompt) + """
        <|turn>user
        用户原始问题：
        \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

        所有工具已执行完成：
        \(resultsBlock)

        请基于以上所有结果回答用户：
        - 如果以上结果已经能回答用户问题，直接给出最终回答，不要重复调用已经成功的工具。
        - 如果还需要继续调用新的工具来补全答案，可以输出一个或多个 `<tool_call>...</tool_call>`。
        - 不要反问，不要提到工具名、Skill、status、result、arguments 等字段。
        - 不要输出 Markdown 代码块，也不要输出 JSON、键名、模板或中间步骤。
        - 不能输出空白。
        <turn|>
        <|turn>model

        """
    }
}
