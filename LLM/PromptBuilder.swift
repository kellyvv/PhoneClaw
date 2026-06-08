import Foundation

// MARK: - Prompt 构造器（Gemma 4 对话模板 + Function Calling）
//
// Gemma 4 使用新 token 格式：
//   <|turn>system\n ... <turn|>
//   <|turn>user\n ... <turn|>
//   <|turn>model\n ... <turn|>

struct PromptBuilder {

    /// 短 persona, 用在 secondary 推理 (tool follow-up 等). 跟 AgentEngine 的
    /// 长 kDefaultSystemPrompt 区分 — 后者是用户可编辑的 SYSPROMPT.md 内容。
    static var defaultSystemPrompt: String { PromptLocale.current.defaultSystemPromptShort }

    // 内部 sentinel 标记, 纯数据, 无需本地化
    private static let thinkingOpenMarker = "[[PHONECLAW_THINK]]"
    private static let thinkingCloseMarker = "[[/PHONECLAW_THINK]]"

    // 发给模型的指令 / 对话内标记, 按当前语言取
    private static var thinkingLanguageInstruction: String { PromptLocale.current.thinkingLanguageInstruction }
    private static var imageHistoryMarker: String { PromptLocale.current.imageHistoryMarker }
    private static var imageFollowUpContextOpenMarker: String { PromptLocale.current.imageFollowUpContextOpenMarker }
    private static var imageFollowUpContextCloseMarker: String { PromptLocale.current.imageFollowUpContextCloseMarker }

    static func multimodalSystemPrompt(hasImages: Bool, hasAudio: Bool, enableThinking: Bool = false) -> String {
        let base: String
        if hasAudio && !hasImages {
            // Pure-audio path: 和 2026-04-18 multimodal-sweep 在 vision 上的发现同因同症 —
            // E2B 在 "什么" 这类极短用户 prompt + 长 system prompt 上概率性给出
            // "这是音乐。" 这种极短保守答案, 正是 "听不清就说听不清, 不要编造" 模板
            // 给小模型递了拒答出口. 空 system prompt 让 audio + text 直接喂给 Gemma 4.
            base = ""
        } else if hasImages && hasAudio {
            // Image + audio 混合分支: 和上面两条同因同症, 同样清空让 multimodal
            // 输入直接喂给 Gemma 4, 不经 refusal 模板.
            base = ""
        } else {
            // Pure-vision (image-only) path: harness (2026-04-18 multimodal-sweep)
            // 证实任何 system prompt 在 E2B chat path 上都会概率性触发"请提供图片"
            // 漂移, 原因是前面的 4 条规则(尤其是"看不清就说看不清"模板)给小模型
            // 递了拒答出口. 空 system prompt 让 image + text 直接喂给 Gemma 4,
            // E2B 在 "看看这张图" 病例上 refusal 60% → 30%. 其他问法本来就稳.
            base = ""
        }

        if enableThinking {
            return base.isEmpty ? thinkingLanguageInstruction : base + "\n" + thinkingLanguageInstruction
        }
        return base
    }

    // internal (not private): 被 LLM/LiveVoice/PromptBuilder+LiveVoice.swift 复用
    static func imagePromptSuffix(count: Int) -> String {
        guard count > 0 else { return "" }
        return "\n" + Array(repeating: "<|image|>", count: count).joined(separator: "\n")
    }

    /// 工具参数提取阶段需要的"当前时间锚点"。
    /// 模型必须知道"现在是何时"才能解析"明天/下午两点"等相对时间表达
    /// 并写出正确的 ISO 8601 字符串。
    /// 用本地时区 (用户设备时区), 周几按当前语言 locale (zh_CN / en_US)
    /// 输出, 方便对应语言模型理解。热修阶段按小时粒度取整, 减少前缀缓存污染。
    private static func currentTimeAnchorBlock() -> String {
        let locale = PromptLocale.current
        let format = locale.timeAnchorFormat
        if let fixed = ProcessInfo.processInfo.environment["PHONECLAW_FIXED_CURRENT_TIME_ANCHOR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fixed.isEmpty {
            return String(format: format, fixed)
        }

        let calendar = Calendar.current
        let now = Date()
        let roundedNow = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: 0,
            second: 0,
            of: now
        ) ?? now

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale.dateFormatterLocaleIdentifier)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let anchor = formatter.string(from: roundedNow)
        return String(format: format, anchor)
    }

    private static func extractSystemBlock(from prompt: String, includeTimeAnchor: Bool = false) -> String {
        let raw: String
        if let turnEnd = prompt.range(of: "<turn|>\n") {
            raw = String(prompt[prompt.startIndex...turnEnd.upperBound])
        } else {
            raw = prompt
        }
        guard includeTimeAnchor else { return raw }
        // 检查两种 locale 的 anchor 前缀 — 对话跨语言切换时仍能识别已注入过的 anchor
        guard !PromptLocale.containsTimeAnchor(raw) else { return raw }
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

    private static func renderedUserHistoryContent(
        for message: ChatMessage,
        includeImageHistoryMarkers: Bool
    ) -> String {
        guard includeImageHistoryMarkers, !message.images.isEmpty else {
            return message.content
        }

        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return imageHistoryMarker
        }
        return trimmed + "\n" + imageHistoryMarker
    }

    private static func renderedCurrentUserContent(
        _ userMessage: String,
        imageFollowUpBridgeSummary: String?
    ) -> String {
        guard let rawSummary = imageFollowUpBridgeSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSummary.isEmpty else {
            return userMessage
        }

        let normalizedSummary = sanitizedAssistantHistoryContent(rawSummary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedSummary: String
        if normalizedSummary.count > 220 {
            clippedSummary = String(normalizedSummary.prefix(220))
        } else {
            clippedSummary = normalizedSummary
        }

        // zh / en 图片追问 bridge 正文 — marker 之外的指令文案也本地化,
        // 否则英文 locale 下 open/close marker 是英文但中间塞一大段中文规则,
        // 会把模型拉回中文回答 (E2B 对 system prompt 里大段中文特别敏感)。
        if LanguageService.shared.current.isChinese {
            return """
            \(imageFollowUpContextOpenMarker)
            上一轮用户发送了图片。
            上一轮对图片的回答：\(clippedSummary)
            如果当前问题是在追问上一轮图片，你必须优先基于以上回答继续作答。
            如果是总结、复述、确认、简化说明，直接基于以上回答生成答案。
            不要要求用户重新上传图片。
            如果仅凭以上回答仍无法确定细节，可以明确说"仅根据上一轮描述无法确定"，但不要要求重新发送图片。
            \(imageFollowUpContextCloseMarker)

            当前问题：
            \(userMessage)
            """
        } else if LanguageService.shared.current.isJapanese {
            return """
            \(imageFollowUpContextOpenMarker)
            前のターンでユーザーは画像を送信しました。
            前のターンでの画像への回答：\(clippedSummary)
            現在の質問が前のターンの画像への追加質問である場合、上記の回答を優先して続けて答えてください。
            要約・言い換え・確認・簡単な説明の場合は、上記の回答からそのまま答えを生成してください。
            ユーザーに画像を再アップロードするよう求めないでください。
            上記の回答だけでは細部を判断できない場合は、「前回の説明だけでは判断できません」とはっきり述べてもかまいませんが、画像の再送信は求めないでください。
            \(imageFollowUpContextCloseMarker)

            現在の質問：
            \(userMessage)
            """
        } else {
            return """
            \(imageFollowUpContextOpenMarker)
            The user sent an image in the previous turn.
            Previous answer about the image: \(clippedSummary)
            If the current question is a follow-up on the previous image, you must continue answering primarily based on the answer above.
            For summaries, restatements, confirmations, or simplifications, generate the answer directly from the above.
            Do not ask the user to upload the image again.
            If the details still cannot be determined from the previous answer alone, you may say "cannot determine from the previous description alone", but do not ask for the image to be resent.
            \(imageFollowUpContextCloseMarker)

            Current question:
            \(userMessage)
            """
        }
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
        return rawBase + tr(
            "\n\n【当前模式: 闲聊】本轮严禁输出 <tool_call>, 严禁提及 Skill / load_skill / 工具调用, 也不要复述 DEVICE_SKILLS / CONTENT_SKILLS / NETWORK_SKILLS 这类内部分类名. 上文所有 Skill 调用规则本轮一律不适用. 回答语言跟随用户当轮输入, 默认简洁. 自我介绍或说明能力时, 用自然短段回答, 不要写成 README、编号清单或系统说明书. 除非用户明确要求拼音、发音、翻译或语言学习, 否则不要附加拼音、罗马音、英文发音或括号解释.",
            "\n\n[Current mode: casual chat] This turn: do NOT emit <tool_call>, do NOT mention Skill / load_skill / tool invocation, and do NOT repeat internal category names such as DEVICE_SKILLS, CONTENT_SKILLS, or NETWORK_SKILLS. All Skill invocation rules above do not apply this turn. Reply in the same language the user used this turn, concise by default. When introducing yourself or explaining capabilities, use short natural prose, not a README, numbered list, or system manual. Unless the user explicitly asks for pinyin, pronunciation, translation, or language learning help, do not add pinyin, romanization, pronunciation guides, or parenthetical language notes.",
            "\n\n【現在のモード: 雑談】今回は <tool_call> を絶対に出力せず, Skill / load_skill / ツール呼び出しに言及せず, DEVICE_SKILLS / CONTENT_SKILLS / NETWORK_SKILLS のような内部カテゴリ名も復唱しないでください. 上記の Skill 呼び出しルールは今回いっさい適用されません. 回答はユーザーが今回使った言語に合わせ, 既定では簡潔に. 自己紹介や能力の説明をするときは, README や番号付きリスト, システム仕様書のようにせず, 自然な短い文章で答えてください. ユーザーが明示的にピンイン・発音・翻訳・語学学習を求めていない限り, ピンイン・ローマ字・英語の発音・かっこ書きの注釈を付け足さないでください."
        )
    }

    /// Preloaded skill block — Router 已经确定性匹配到 skill 时直接带它们的 body
    /// 进第一轮 prompt, 跳过 load_skill 往返。小模型(E2B/E4B)在多轮工具调用
    /// 上的成功率由此大幅提升。
    struct PreloadedSkill {
        let id: String
        let displayName: String
        /// Full SKILL.md body — 旧字段, Live voice 路径仍在用. 主 agent 路径改用 compactSchema.
        let body: String
        let allowedTools: [String]
        /// Path 1 (2026-04-17): 主 agent 路径用紧凑 schema (~200 chars/SKILL) 替代
        /// 完整 SKILL body (~3000 chars/SKILL). E4B 真机 multi-SKILL 场景 streamingPrompt
        /// 从 ~5000 chars 降到 ~2000 chars, prefill 内存峰值显著下降, jetsam 不再触发.
        /// 模型还能拿到 tool 调用 schema, 不丢调用能力. SKILL.md 里的"行为细则"
        /// (e.g., 跨轮参数合并, 软参不追问) 暂时不进 prompt — 实际跑 HARNESS 验证质量损失.
        let compactSchema: String

        /// 构造紧凑 schema. tools 是 ToolRegistry 里这个 SKILL 注册的 RegisteredTool 列表.
        static func makeCompactSchema(skillName: String, tools: [(name: String, description: String, parameters: String, requiredParameters: [String])]) -> String {
            if tools.isEmpty {
                return tr(
                    "（content-type SKILL, 无 tool, 按 SKILL 指令直接生成文本结果）",
                    "(content-type SKILL, no tools — generate text result directly per SKILL instructions)",
                    "（content-type の SKILL, ツールなし — SKILL の指示に従ってテキスト結果を直接生成）"
                )
            }
            var lines: [String] = []
            for t in tools {
                lines.append("- `\(t.name)`: \(t.description)")
                lines.append("  \(tr("参数", "Parameters", "パラメータ")): \(t.parameters)")
                if !t.requiredParameters.isEmpty {
                    lines.append("  \(tr("必填", "Required", "必須")): \(t.requiredParameters.joined(separator: ", "))")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// 构造完整 Prompt（包含工具定义 + 对话历史）
    static func build(
        userMessage: String,
        currentImageCount: Int = 0,
        tools: [SkillInfo],
        includeTimeAnchor: Bool = false,
        includeImageHistoryMarkers: Bool = false,
        imageFollowUpBridgeSummary: String? = nil,
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
        // 按 SkillType 分组, 给模型不同调用规则。
        let deviceSkills = tools.filter { $0.type == .device }
        let contentSkills = tools.filter { $0.type == .content }
        let networkSkills = tools.filter { $0.type == .network }
        func renderList(_ list: [SkillInfo]) -> String {
            if list.isEmpty { return tr("（无）\n", "(none)\n", "（なし）\n") }
            return list.map { "- **\($0.name)**: \($0.description)" }.joined(separator: "\n") + "\n"
        }
        // Router 已锁定时, system prompt 的全 skill 列表是冗余的——locked ability
        // section 已经给了具体 tool 和 compactSchema, 模型不需要再看一遍其他 skill 的
        // 一句话描述. 用短标记替代, 给 E4B 1300 input budget 节省 ~200 token (~800 chars).
        // 不影响 quality: model 决策依赖 locked section 的精准信息, 不依赖列表的广播.
        let isPreloaded = !preloadedSkills.isEmpty
        let deviceListText: String
        let contentListText: String
        let networkListText: String
        if isPreloaded {
            let markerText = tr("（已锁定能力见下方 — Locked ability shown below）\n", "(locked ability shown below)\n", "（ロック済みの機能は下記を参照）\n")
            deviceListText = markerText
            contentListText = markerText
            networkListText = markerText
        } else {
            deviceListText = renderList(deviceSkills)
            contentListText = renderList(contentSkills)
            networkListText = renderList(networkSkills)
        }
        // 兼容旧版 SYSPROMPT.md (仅 ___SKILLS___) 的扁平列表
        let flatListText: String = {
            var s = ""
            for skill in tools { s += "- **\(skill.name)**: \(skill.description)\n" }
            return s
        }()

        if isMultimodalTurn {
            prompt += basePrompt
        } else if basePrompt.contains("___DEVICE_SKILLS___")
            || basePrompt.contains("___CONTENT_SKILLS___")
            || basePrompt.contains("___NETWORK_SKILLS___") {
            // 新版分类占位符: 按类别分别注入
            var resolved = basePrompt
            resolved = resolved.replacingOccurrences(of: "___DEVICE_SKILLS___", with: deviceListText)
            resolved = resolved.replacingOccurrences(of: "___CONTENT_SKILLS___", with: contentListText)
            resolved = resolved.replacingOccurrences(of: "___NETWORK_SKILLS___", with: networkListText)
            prompt += resolved
        } else if basePrompt.contains("___SKILLS___") {
            // 旧版扁平占位符: 保留向后兼容
            prompt += basePrompt.replacingOccurrences(of: "___SKILLS___", with: flatListText)
        } else {
            // SYSPROMPT.md 不含任何占位符时的兜底：只追加技能列表，不追加指令。
            prompt += basePrompt
            if !tools.isEmpty {
                prompt += tr(
                    "\n\n你拥有以下能力（Skill）：\n\n",
                    "\n\nYou have the following abilities (Skills):\n\n",
                    "\n\nあなたは以下の機能（Skill）を持っています：\n\n"
                ) + flatListText
            }
        }

        // 仅全量注入（无匹配命中）时，提示模型可通过 list_skills 发现更多能力
        if showListSkillsHint && !isMultimodalTurn {
            prompt += tr(
                "\n如果以上列出的能力都不匹配用户需求，可以调用 list_skills 查询更多能力：\n<tool_call>\n{\"name\": \"list_skills\", \"arguments\": {\"query\": \"用户需求描述\"}}\n</tool_call>\n",
                "\nIf none of the abilities above match the user's needs, you can call list_skills to discover more:\n<tool_call>\n{\"name\": \"list_skills\", \"arguments\": {\"query\": \"<user need description>\"}}\n</tool_call>\n",
                "\n上記の機能がどれもユーザーの要望に合わない場合は、list_skills を呼び出してさらに機能を検索できます：\n<tool_call>\n{\"name\": \"list_skills\", \"arguments\": {\"query\": \"ユーザーの要望の説明\"}}\n</tool_call>\n"
            )
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
            prompt += tr(
                "【已锁定能力 — 直接调用工具, 不需要先 load_skill】\n",
                "[Locked ability — call tools directly, no need to load_skill first]\n",
                "【ロック済みの機能 — ツールを直接呼び出し, 先に load_skill する必要はありません】\n"
            )
            if allAllowed.isEmpty {
                prompt += tr(
                    "当前锁定的 Skill 没有工具, 按 Skill 指令直接给最终答案, 禁止输出 <tool_call>。\n",
                    "The locked Skill has no tools. Follow the Skill instructions and give the final answer directly. Do not emit <tool_call>.\n",
                    "現在ロックされている Skill にはツールがありません. Skill の指示に従って最終的な答えを直接出し, <tool_call> は出力しないでください。\n"
                )
            } else {
                prompt += tr(
                    "\n可调用的工具 (只允许这些名字, 其他名字一律视为非法, 不要凭空编造):\n",
                    "\nCallable tools (only these names; any other name is illegal, do not fabricate):\n",
                    "\n呼び出せるツール (これらの名前のみ許可, それ以外の名前はすべて不正とみなし, 勝手に作らないでください):\n"
                )
                prompt += allAllowed.map { "- `\($0)`" }.joined(separator: "\n") + "\n"
                prompt += tr(
                    "\n如果需要操作, 输出:\n<tool_call>\n{\"name\": \"<上面列表中的名字>\", \"arguments\": {...}}\n</tool_call>\n",
                    "\nIf action is needed, emit:\n<tool_call>\n{\"name\": \"<a name from the list above>\", \"arguments\": {...}}\n</tool_call>\n",
                    "\n操作が必要な場合は, 次を出力:\n<tool_call>\n{\"name\": \"<上のリストにある名前>\", \"arguments\": {...}}\n</tool_call>\n"
                )
                prompt += tr(
                    "如果不需要工具就直接给最终答案正文。**不要**再调用 load_skill, 已经加载好了。\n",
                    "If no tools are needed, give the final answer directly. **Do not** call load_skill again — it's already loaded.\n",
                    "ツールが不要なら最終的な答えの本文を直接出してください。**load_skill を再度呼び出さないでください**, すでに読み込み済みです。\n"
                )
            }
            for sk in preloadedSkills {
                prompt += "\n━━ Skill: \(sk.displayName) ━━\n"
                prompt += "<untrusted_skill_instruction_block>\n"
                prompt += sanitizedPreloadedSkillInstructions(sk.compactSchema) + "\n"
                prompt += "</untrusted_skill_instruction_block>\n"
            }
            prompt += "━━━━━━━━━━━━━━━━━━━━\n"
        }

        if enableThinking && !isMultimodalTurn {
            prompt += "\n\n" + thinkingLanguageInstruction
        }

        // 时间锚点只在显式声明需要解析相对时间的 skill 上注入，避免污染通用文本前缀。
        if includeTimeAnchor && !isMultimodalTurn {
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
                prompt += "<|turn>user\n\(renderedUserHistoryContent(for: msg, includeImageHistoryMarkers: includeImageHistoryMarkers))<turn|>\n"
            case .assistant:
                let assistantContent = sanitizedAssistantHistoryContent(msg.content)
                prompt += "<|turn>model\n\(assistantContent)<turn|>\n"
            case .system:
                if let skillName = msg.skillName {
                    prompt += "<|turn>model\n<tool_call>\n{\"name\": \"\(skillName)\", \"arguments\": {}}\n</tool_call><turn|>\n"
                }
            case .skillResult:
                guard msg.skillResultKind != .skillInstructions else { continue }
                let skillLabel = msg.skillName ?? "tool"
                // History 的 skill result 用当前语言 label. 历史 prompt 里 Chinese
                // label 会把英文模型 drift 回中文 (E2B 对前文语言特别敏感)。
                let resultText: String
                if msg.skillResultKind == .generatedContent {
                    resultText = tr(
                        "Skill \(skillLabel) 生成的内容：\(msg.content)",
                        "Generated content from skill \(skillLabel): \(msg.content)",
                        "Skill \(skillLabel) が生成した内容：\(msg.content)"
                    )
                } else {
                    resultText = tr(
                        "工具 \(skillLabel) 的执行结果：\(msg.content)",
                        "Result of tool \(skillLabel): \(msg.content)",
                        "ツール \(skillLabel) の実行結果：\(msg.content)"
                    )
                }
                prompt += "<|turn>user\n" + resultText + "<turn|>\n"
            }
        }

        // 当前用户消息
        let currentUserContent = renderedCurrentUserContent(
            userMessage,
            imageFollowUpBridgeSummary: imageFollowUpBridgeSummary
        )
        prompt += "<|turn>user\n\(currentUserContent)\(imagePromptSuffix(count: currentImageCount))<turn|>\n"
        prompt += "<|turn>model\n"

        return prompt
    }

    private static func sanitizedPreloadedSkillInstructions(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "<untrusted_skill_instruction_block>", with: "[escaped-skill-block-tag]")
            .replacingOccurrences(of: "</untrusted_skill_instruction_block>", with: "[escaped-skill-block-tag]")
            .replacingOccurrences(of: "<|turn>", with: "<|turn escaped>")
            .replacingOccurrences(of: "<turn|>", with: "<turn escaped>")
    }

    static func buildLightweightTextPrompt(
        userMessage: String,
        history: [ChatMessage] = [],
        systemPrompt: String? = nil,
        enableThinking: Bool = false,
        historyDepth: Int = 2,
        includeImageHistoryMarkers: Bool = false,
        imageFollowUpBridgeSummary: String? = nil
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
                prompt += "<|turn>user\n\(renderedUserHistoryContent(for: msg, includeImageHistoryMarkers: includeImageHistoryMarkers))<turn|>\n"
            case .assistant:
                let assistantContent = sanitizedAssistantHistoryContent(msg.content)
                guard !assistantContent.isEmpty else { continue }
                prompt += "<|turn>model\n\(assistantContent)<turn|>\n"
            case .system, .skillResult:
                continue
            }
        }

        let currentUserContent = renderedCurrentUserContent(
            userMessage,
            imageFollowUpBridgeSummary: imageFollowUpBridgeSummary
        )
        prompt += "<|turn>user\n\(currentUserContent)<turn|>\n"
        prompt += "<|turn>model\n"
        return prompt
    }

    static func buildImageFollowUpDecisionPrompt(
        assistantSummary: String,
        userQuestion: String
    ) -> String {
        let normalizedSummary = assistantSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedSummary: String
        if normalizedSummary.count > 240 {
            clippedSummary = String(normalizedSummary.prefix(240))
        } else {
            clippedSummary = normalizedSummary
        }

        // Decision classifier 的输出标签 (NORMAL_TEXT / IMAGE_TEXT / RE_MULTIMODAL)
        // 语言无关, 但任务指令要按当前语言给。
        let systemBody: String
        let userHeader: String
        let questionLabel: String
        if LanguageService.shared.current.isChinese {
            systemBody = """
            你只做一个三分类判断。
            如果用户的新问题和上一张图片无关，输出 NORMAL_TEXT。
            如果用户的新问题是在追问上一张图片，但仅凭已有文字回答就能继续回答，输出 IMAGE_TEXT。
            如果用户的新问题必须重新查看上一张图片的视觉细节才能可靠回答，输出 RE_MULTIMODAL。
            只输出这三个标签中的一个，不要输出任何别的字。
            """
            userHeader = "最近一轮与图片相关的助手回答："
            questionLabel = "用户新问题："
        } else if LanguageService.shared.current.isJapanese {
            systemBody = """
            あなたは3分類の判定だけを行います。
            ユーザーの新しい質問が前の画像と無関係なら、NORMAL_TEXT を出力します。
            ユーザーの新しい質問が前の画像への追加質問だが、既存のテキスト回答だけで答えられるなら、IMAGE_TEXT を出力します。
            ユーザーの新しい質問に確実に答えるには前の画像の視覚的な細部を見直す必要があるなら、RE_MULTIMODAL を出力します。
            この3つのラベルのうち1つだけを出力し、それ以外は一切出力しないでください。
            """
            userHeader = "画像に関連する直近のアシスタントの回答："
            questionLabel = "ユーザーの新しい質問："
        } else {
            systemBody = """
            You do one 3-way classification only.
            If the user's new question is unrelated to the previous image, output NORMAL_TEXT.
            If the user's new question is a follow-up on the previous image but can be answered using only the existing text answer, output IMAGE_TEXT.
            If the user's new question requires re-examining the visual details of the previous image to answer reliably, output RE_MULTIMODAL.
            Output only one of these three labels, nothing else.
            """
            userHeader = "Most recent assistant answer related to the image:"
            questionLabel = "User's new question:"
        }

        return """
        <|turn>system
        \(systemBody)
        <turn|>
        <|turn>user
        \(userHeader)
        \(clippedSummary)

        \(questionLabel)
        \(userQuestion)
        <turn|>
        <|turn>model
        """
    }

    static func buildSkillIntentRoutingPrompt(
        userQuestion: String,
        availableNetworkSkillsSummary: String
    ) -> String {
        let trimmedQuestion = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedQuestion = trimmedQuestion.count > 500
            ? String(trimmedQuestion.prefix(500))
            : trimmedQuestion

        let systemBody: String
        let skillsLabel: String
        let questionLabel: String
        if LanguageService.shared.current.isChinese {
            systemBody = """
            你只做路由分类, 不回答用户问题。
            判断用户这个问题是否需要调用下面某个 network skill。
            network skill 只用于公开互联网或网页相关能力。
            如果可靠回答必须依赖当前、近期、实时、会随时间变化、会随地点变化、或需要网页查证的公开信息, 输出最合适的 skill id。
            不要因为用户没有写"搜索"或"联网"就输出 none; 要根据问题本身是否需要外部公开信息来判断。
            如果不需要外部网页信息, 输出 none。
            只输出一个 skill id 或 none, 不要解释, 不要输出 JSON, 不要输出 `<tool_call>`。
            """
            skillsLabel = "可用 network skills:"
            questionLabel = "用户问题:"
        } else if LanguageService.shared.current.isJapanese {
            systemBody = """
            あなたはルーティング分類だけを行い, ユーザーの質問には答えません。
            このユーザーの質問が下記のいずれかの network skill を必要とするか判断してください。
            network skill は公開インターネットやウェブページに関する機能のみに使います。
            確実な回答が, 現在・最近・リアルタイム・時間とともに変化する・場所によって変化する, またはウェブで確認が必要な公開情報に依存する場合は, 最も適切な skill id を出力してください。
            ユーザーが「検索」や「ネット」と書いていないという理由だけで none を出力しないでください; 質問そのものが外部の公開情報を必要とするかどうかで判断してください。
            外部のウェブ情報が不要なら, none を出力してください。
            skill id を1つ, または none だけを出力し, 説明も JSON も `<tool_call>` も出力しないでください。
            """
            skillsLabel = "利用可能な network skills:"
            questionLabel = "ユーザーの質問:"
        } else {
            systemBody = """
            You only classify routing; do not answer the user.
            Decide whether this user message needs one of the network skills below.
            A network skill is only for public internet or webpage capabilities.
            If a reliable answer depends on current, recent, live, time-varying, location-varying, or web-verifiable public information, output the best skill id.
            Do not output none merely because the user did not explicitly say "search" or "browse"; decide from whether the question itself requires external public information.
            If no external web information is needed, output none.
            Output exactly one skill id or none. Do not explain, do not output JSON, and do not emit `<tool_call>`.
            """
            skillsLabel = "Available network skills:"
            questionLabel = "User message:"
        }

        return """
        <|turn>system
        \(systemBody)

        \(skillsLabel)
        \(availableNetworkSkillsSummary)
        <turn|>
        <|turn>user
        \(questionLabel)
        \(clippedQuestion)
        <turn|>
        <|turn>model
        """
    }

    static func buildDialogueActPrompt(
        userQuestion: String,
        previousContextKind: String = "tool_result",
        previousSourceName: String,
        previousToolName: String?,
        previousResultSummary: String
    ) -> String {
        let clippedQuestion = compactToolResultSummary(userQuestion, maxCharacters: 500)
        let clippedSummary = compactToolResultSummary(previousResultSummary, maxCharacters: 1_200)
        let previousTool = previousToolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolLineZh: String
        let toolLineEn: String
        let toolLineJa: String
        if let previousTool, !previousTool.isEmpty {
            toolLineZh = "上一轮工具: \(previousTool)\n"
            toolLineEn = "Previous tool: \(previousTool)\n"
            toolLineJa = "前のターンのツール: \(previousTool)\n"
        } else {
            toolLineZh = ""
            toolLineEn = ""
            toolLineJa = ""
        }
        if LanguageService.shared.current.isChinese {
            return """
            <|turn>system
            你只做对话行为分类, 不回答用户问题, 不调用工具。
            判断当前用户消息和上一轮上下文产物之间的关系。输出必须是一个 JSON object。

            可选 act:
            - new_task: 用户提出了新的独立任务或新问题
            - continue_task: 用户要继续上一任务的下一步
            - correct_parameters: 用户在纠正上一轮参数、范围、对象或条件
            - refresh_result: 用户明确要求重新获取、刷新、再查一次
            - verify_last_result: 用户在核对上一轮结果是否可信、是否确定
            - explain_last_result: 用户要解释上一轮结果为什么这样、含义是什么
            - clarify_last_result: 用户要澄清上一轮结果中的某个细节
            - elaborate_last_result: 用户要展开、补充、举例或继续说明上一轮内容
            - transform_last_result: 用户要对上一轮内容做结构化、总结、改写、翻译、转格式、列要点、列清单、转表格或类似二次加工
            - cancel_or_reject: 用户取消、否定或拒绝继续
            - chitchat: 闲聊或不需要工具的自然回复

            决策原则:
            - “上一轮上下文产物”可以是上一轮助手回答、工具结果、图片回答或生成内容; 当前消息可能是在继续、核对或加工这个产物。
            - 最高优先级: 如果当前消息指出上一轮的范围、对象、时间、数量、地点、实体、条件不对, 并给出替代值或新约束, act 必须是 correct_parameters, target 必须是 previous_result, should_execute_tool 必须是 true。
            - 如果当前消息是省略式追问, 只给出新的时间、范围、对象、地点、实体或条件片段, 并且需要沿用上一轮能力才能回答, act 必须是 correct_parameters 或 continue_task, target 必须是 previous_result, should_execute_tool 必须是 true。
            - 如果最近工具能力本身是查询、读取、搜索、查看或列出信息, 且当前消息用“那/再/换/then/what about”等承接词给出新对象或新范围, 应复用最近工具能力执行。
            - 如果当前消息只是核对、质疑、解释、澄清、展开或加工上一轮产物, 不要重新执行工具。
            - 如果当前消息要求“总结/结构化/整理/改写/翻译/列要点/转表格/转 Markdown/转 JSON”等, 且没有提供新的待处理正文, act 必须是 transform_last_result, target 必须是 previous_result, should_execute_tool 必须是 false。
            - 如果当前消息自己提供了新的待处理正文、链接、图片、文件或明确新主题, act 必须是 new_task, target 必须是 new_task。
            - 如果当前消息改了范围/对象/条件, 或明确要求重新获取, 才允许继续执行工具。
            - 不要根据某个具体业务词做判断; 只根据对话行为和上一轮结果的关系判断。
            - 占位示例: “不是 <旧值>, 是 <新值>”/“改成 <新值>”/“use <new value> instead” 属于 correct_parameters, 不是 verify_last_result。
            - 占位示例: “那查 <新时间/新范围/新对象> 的”/“换成 <新条件>”/“what about <new scope>?” 属于 correct_parameters 或 continue_task, should_execute_tool=true。
            - 占位示例: “确定吗?”/“是真的吗?”/“why so low?” 属于 verify_last_result 或 explain_last_result, should_execute_tool=false。
            - 占位示例: “帮我结构化”/“总结三点”/“make it a table” 属于 transform_last_result, should_execute_tool=false。

            JSON schema:
            {"act":"...", "target":"previous_result|new_task|none", "should_execute_tool":true|false, "confidence":0.0}
            只输出 JSON, 不要 Markdown、解释、代码块或 `<tool_call>`。
            <turn|>
            <|turn>user
            上一轮产物类型: \(previousContextKind)
            上一轮来源: \(previousSourceName)
            \(toolLineZh)上一轮产物摘要:
            \(clippedSummary)

            当前用户消息:
            \(clippedQuestion)
            <turn|>
            <|turn>model

            """
        } else if LanguageService.shared.current.isJapanese {
            return """
            <|turn>system
            あなたは対話行為の分類だけを行い, ユーザーの質問には答えず, ツールも呼び出しません。
            現在のユーザーメッセージと前のターンの文脈成果物との関係を判断してください。出力は必ず1つの JSON object にしてください。

            選択できる act:
            - new_task: ユーザーが新しい独立したタスクや質問を出した
            - continue_task: ユーザーが前のタスクの次のステップを進めたい
            - correct_parameters: ユーザーが前のターンのパラメータ・範囲・対象・条件を訂正している
            - refresh_result: ユーザーが取得し直す・更新する・もう一度調べるよう明示的に求めている
            - verify_last_result: ユーザーが前のターンの結果が信頼できるか・確かかを確認している
            - explain_last_result: ユーザーが前のターンの結果がなぜそうなのか・何を意味するのかを尋ねている
            - clarify_last_result: ユーザーが前のターンの結果のある細部の明確化を求めている
            - elaborate_last_result: ユーザーが前のターンの内容の展開・補足・例示・続きを求めている
            - transform_last_result: ユーザーが前のターンの内容を構造化・要約・書き換え・翻訳・形式変換・箇条書き・チェックリスト・表など二次加工することを求めている
            - cancel_or_reject: ユーザーが取り消し・否定・続行の拒否をしている
            - chitchat: 雑談, またはツールを必要としない自然な返答

            判断の原則:
            - 「前のターンの文脈成果物」は, 前のターンのアシスタント回答・ツール結果・画像への回答・生成された内容のいずれでもあり得ます; 現在のメッセージはそれを継続・確認・加工しているかもしれません。
            - 最優先: 現在のメッセージが前のターンの範囲・対象・時間・数量・場所・実体・条件が誤っていると指摘し, 代わりの値や新しい制約を示している場合, act は必ず correct_parameters, target は必ず previous_result, should_execute_tool は必ず true にしてください。
            - 現在のメッセージが省略的な追加質問で, 新しい時間・範囲・対象・場所・実体・条件の断片だけを示し, 前のターンの能力を流用しないと答えられない場合, act は必ず correct_parameters または continue_task, target は必ず previous_result, should_execute_tool は必ず true にしてください。
            - 直近のツール能力自体が情報の検索・読み取り・調査・確認・一覧化であり, 現在のメッセージが「それ/また/変えて/then/what about」などの受け継ぎ表現で新しい対象や範囲を示している場合は, 直近のツール能力を流用して実行してください。
            - 現在のメッセージが前のターンの成果物を確認・疑問・説明・明確化・展開・加工しているだけなら, ツールを再実行しないでください。
            - 現在のメッセージが「要約/構造化/整理/書き換え/翻訳/箇条書き/表に/Markdown に/JSON に」などを求めており, 新しく処理すべき本文を提供していない場合, act は必ず transform_last_result, target は必ず previous_result, should_execute_tool は必ず false にしてください。
            - 現在のメッセージ自体が新しい処理対象の本文・リンク・画像・ファイル, または明らかに新しいトピックを提供している場合, act は必ず new_task, target は必ず new_task にしてください。
            - 現在のメッセージが範囲/対象/条件を変えた場合, または取得し直すよう明示的に求めた場合のみ, ツールの続行実行を許可します。
            - 特定の業務語そのもので判断しないでください; 対話行為と前のターンの結果との関係だけで判断してください。
            - 例: 「<旧値> ではなく <新値>」/「<新値> に変えて」/「use <new value> instead」は correct_parameters であり, verify_last_result ではありません。
            - 例: 「では <新しい時間/新しい範囲/新しい対象> を調べて」/「<新しい条件> に変えて」/「what about <new scope>?」は correct_parameters または continue_task で, should_execute_tool=true です。
            - 例: 「確かですか?」/「本当ですか?」/「why so low?」は verify_last_result または explain_last_result で, should_execute_tool=false です。
            - 例: 「構造化して」/「3点に要約して」/「make it a table」は transform_last_result で, should_execute_tool=false です。

            JSON schema:
            {"act":"...", "target":"previous_result|new_task|none", "should_execute_tool":true|false, "confidence":0.0}
            JSON だけを出力し, Markdown・説明・コードブロック・`<tool_call>` は出力しないでください。
            <turn|>
            <|turn>user
            前のターンの成果物タイプ: \(previousContextKind)
            前のターンの出所: \(previousSourceName)
            \(toolLineJa)前のターンの成果物の要約:
            \(clippedSummary)

            現在のユーザーメッセージ:
            \(clippedQuestion)
            <turn|>
            <|turn>model

            """
        } else {
            return """
            <|turn>system
            You only classify the dialogue act. Do not answer the user and do not call tools.
            Decide how the current user message relates to the previous context artifact. Output exactly one JSON object.

            Allowed act values:
            - new_task: the user asks a new independent task or question
            - continue_task: the user wants the next step of the previous task
            - correct_parameters: the user corrects the previous range, entity, object, or condition
            - refresh_result: the user explicitly asks to fetch, refresh, rerun, or check again
            - verify_last_result: the user is checking whether the previous result is reliable or certain
            - explain_last_result: the user asks why the previous result is that way or what it means
            - clarify_last_result: the user asks for a detail about the previous result
            - elaborate_last_result: the user wants the previous result expanded, continued, supplemented, or illustrated with an example
            - transform_last_result: the user wants the previous result summarized, structured, rewritten, translated, converted to another format, turned into bullets, a checklist, a table, Markdown, JSON, or similar
            - cancel_or_reject: the user cancels, rejects, or refuses to continue
            - chitchat: casual conversation or a reply that needs no tool

            Decision principles:
            - "Previous context artifact" may be the previous assistant answer, tool result, image answer, or generated content. The current message may continue, verify, explain, clarify, expand, or transform it.
            - Highest priority: if the current message says the previous scope, object, time, count, location, entity, or condition was wrong and provides a replacement value or new constraint, act must be correct_parameters, target must be previous_result, and should_execute_tool must be true.
            - If the current message is an elliptical follow-up that only supplies a new time, range, object, location, entity, or condition fragment, and answering requires reusing the previous capability, act must be correct_parameters or continue_task, target must be previous_result, and should_execute_tool must be true.
            - If the recent capability was itself querying, reading, searching, checking, or listing information, and the current message uses a continuation like "then", "again", "switch to", or "what about" plus a new object or scope, reuse the recent capability and execute the tool.
            - If the message only verifies, challenges, explains, clarifies, expands, or transforms the previous artifact, do not execute a tool again.
            - If the message asks to "summarize / structure / rewrite / translate / list key points / make a table / convert to Markdown or JSON" and does not provide new content to process, act must be transform_last_result, target must be previous_result, and should_execute_tool must be false.
            - If the message itself provides new content, a link, image, file, or a clearly new topic, act must be new_task, target must be new_task.
            - If the message changes scope/entity/conditions, or explicitly asks to fetch again, allow tool execution.
            - Do not rely on domain-specific keyword lists; judge the dialogue act and relation to the previous result.
            - Placeholder example: “not <old value>, <new value>” / “change it to <new value>” / “use <new value> instead” is correct_parameters, not verify_last_result.
            - Placeholder example: “then check <new time/range/object>” / “switch to <new condition>” / “what about <new scope>?” is correct_parameters or continue_task, should_execute_tool=true.
            - Placeholder example: “are you sure?” / “really?” / “why so low?” is verify_last_result or explain_last_result, should_execute_tool=false.
            - Placeholder example: “structure this” / “summarize in three points” / “make it a table” is transform_last_result, should_execute_tool=false.

            JSON schema:
            {"act":"...", "target":"previous_result|new_task|none", "should_execute_tool":true|false, "confidence":0.0}
            Output only JSON. No Markdown, explanations, code blocks, or `<tool_call>`.
            <turn|>
            <|turn>user
            Previous artifact type: \(previousContextKind)
            Previous source: \(previousSourceName)
            \(toolLineEn)Previous artifact summary:
            \(clippedSummary)

            Current user message:
            \(clippedQuestion)
            <turn|>
            <|turn>model

            """
        }
    }

    static func buildPreviousContextArtifactReplyPrompt(
        userQuestion: String,
        dialogueAct: String,
        contextKind: String,
        previousSourceName: String,
        previousToolName: String?,
        previousVisibleAnswer: String?,
        previousResultSummary: String,
        previousResultDetail: String,
        enableThinking: Bool = false
    ) -> String {
        let visibleAnswer = compactToolResultSummary(previousVisibleAnswer ?? "", maxCharacters: 2_400)
        let summary = compactToolResultSummary(previousResultSummary, maxCharacters: 1_800)
        let detail = compactToolResultSummary(previousResultDetail, maxCharacters: 3_200)
        let previousTool = previousToolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolLineZh: String
        let toolLineEn: String
        let toolLineJa: String
        if let previousTool, !previousTool.isEmpty {
            toolLineZh = "\n上一轮工具:\n\(previousTool)\n"
            toolLineEn = "\nPrevious tool:\n\(previousTool)\n"
            toolLineJa = "\n前のターンのツール:\n\(previousTool)\n"
        } else {
            toolLineZh = ""
            toolLineEn = ""
            toolLineJa = ""
        }
        let visibleBlockZh = visibleAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : """

            上一轮展示给用户的回答:
            \(visibleAnswer)
            """
        let visibleBlockEn = visibleAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : """

            Previous answer shown to the user:
            \(visibleAnswer)
            """
        let visibleBlockJa = visibleAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : """

            前のターンでユーザーに表示した回答:
            \(visibleAnswer)
            """
        let thinkingPrefix = enableThinking ? "<|think|>" : ""
        let thinkingInstruction = enableThinking ? "\n\n\(thinkingLanguageInstruction)" : ""
        if LanguageService.shared.current.isChinese {
            return """
            <|turn>system
            \(thinkingPrefix)\(defaultSystemPrompt)
            你正在回答一个针对上一轮上下文产物的追问。
            不要调用工具, 不要输出 `<tool_call>`, 不要声称已经重新读取、重新搜索、刷新或重新查看数据。
            只基于下面给出的上一轮上下文产物回答。
            如果对话行为是 transform_last_result, 直接按用户当前要求对上一轮内容做结构化、总结、改写、翻译、转格式、列要点或制表。
            如果对话行为是 elaborate_last_result, 直接展开、补充或举例说明上一轮内容。
            如果用户在核对可信度, 说明这是基于上一轮返回/展示的内容, 并给出必要限制。
            如果上一轮内容里已有来源链接或引用网址, 整理时保留相关来源；不要编造新来源。
            只要下面提供了上一轮内容, 就不要回答“请提供文本/信息”。
            回答要简洁, 不要复读内部字段名。
            \(thinkingInstruction)
            <turn|>
            <|turn>user
            当前用户追问:
            \(userQuestion)

            对话行为:
            \(dialogueAct)

            上一轮产物类型:
            \(contextKind)

            上一轮来源:
            \(previousSourceName)\(toolLineZh)\(visibleBlockZh)

            上一轮产物摘要:
            \(summary)

            上一轮产物原始/补充内容:
            \(detail)
            <turn|>
            <|turn>model

            """
        } else if LanguageService.shared.current.isJapanese {
            return """
            <|turn>system
            \(thinkingPrefix)\(defaultSystemPrompt)
            あなたは前のターンの文脈成果物に対する追加質問に答えています。
            ツールを呼び出さず, `<tool_call>` を出力せず, データを読み直した・検索し直した・更新した・見直したと主張しないでください。
            下記に示す前のターンの文脈成果物だけに基づいて答えてください。
            対話行為が transform_last_result の場合は, ユーザーの今の要求どおり前のターンの内容を構造化・要約・書き換え・翻訳・形式変換・箇条書き・表にしてください。
            対話行為が elaborate_last_result の場合は, 前のターンの内容を展開・補足・例示してください。
            ユーザーが信頼性を確認している場合は, それが前のターンで返された/表示された内容に基づくものだと述べ, 必要な制限も示してください。
            前のターンの内容にすでにソースのリンクや引用 URL があれば, 整理する際に関連するソースを残してください; 新しいソースを捏造しないでください。
            下記に前のターンの内容が提供されている限り, 「テキスト/情報を提供してください」とは答えないでください。
            回答は簡潔にし, 内部のフィールド名を復唱しないでください。
            \(thinkingInstruction)
            <turn|>
            <|turn>user
            現在のユーザーの追加質問:
            \(userQuestion)

            対話行為:
            \(dialogueAct)

            前のターンの成果物タイプ:
            \(contextKind)

            前のターンの出所:
            \(previousSourceName)\(toolLineJa)\(visibleBlockJa)

            前のターンの成果物の要約:
            \(summary)

            前のターンの成果物の元データ/補足内容:
            \(detail)
            <turn|>
            <|turn>model

            """
        } else {
            return """
            <|turn>system
            \(thinkingPrefix)\(defaultSystemPrompt)
            You are answering a follow-up about the previous context artifact.
            Do not call tools, do not emit `<tool_call>`, and do not claim that you re-read, re-searched, refreshed, reran, or re-viewed anything.
            Answer only from the previous context artifact below.
            If the dialogue act is transform_last_result, directly transform the previous content as requested: structure, summarize, rewrite, translate, convert format, list key points, or make a table.
            If the dialogue act is elaborate_last_result, directly expand, continue, supplement, or give examples from the previous content.
            If the user is verifying reliability, say it is based on the previous returned/shown content and mention necessary limitations.
            If the previous content already has source links, preserve relevant sources while reorganizing; do not invent new sources.
            As long as previous content is provided below, do not ask the user to provide text or information.
            Keep the answer concise and do not repeat internal field names.
            \(thinkingInstruction)
            <turn|>
            <|turn>user
            Current follow-up:
            \(userQuestion)

            Dialogue act:
            \(dialogueAct)

            Previous artifact type:
            \(contextKind)

            Previous source:
            \(previousSourceName)\(toolLineEn)\(visibleBlockEn)

            Previous artifact summary:
            \(summary)

            Previous raw/additional content:
            \(detail)
            <turn|>
            <|turn>model

            """
        }
    }

    static func buildPreviousToolObservationReplyPrompt(
        userQuestion: String,
        dialogueAct: String,
        previousSkillName: String,
        previousToolName: String,
        previousResultSummary: String,
        previousResultDetail: String,
        enableThinking: Bool = false
    ) -> String {
        buildPreviousContextArtifactReplyPrompt(
            userQuestion: userQuestion,
            dialogueAct: dialogueAct,
            contextKind: "tool_result",
            previousSourceName: previousSkillName,
            previousToolName: previousToolName,
            previousVisibleAnswer: nil,
            previousResultSummary: previousResultSummary,
            previousResultDetail: previousResultDetail,
            enableThinking: enableThinking
        )
    }

    static func buildImageFollowUpTextPrompt(
        userMessage: String,
        assistantSummary: String,
        systemPrompt: String? = nil,
        enableThinking: Bool = false
    ) -> String {
        let normalizedSummary = sanitizedAssistantHistoryContent(assistantSummary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedSummary: String
        if normalizedSummary.count > 280 {
            clippedSummary = String(normalizedSummary.prefix(280))
        } else {
            clippedSummary = normalizedSummary
        }

        var prompt = "<|turn>system\n"
        if enableThinking {
            prompt += "<|think|>"
        }
        let basePrompt = (systemPrompt ?? defaultSystemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        prompt += basePrompt
        if LanguageService.shared.current.isChinese {
            prompt += "\n\n你正在继续回答同一张图片相关的追问。"
            prompt += "\n你只能基于下面给出的上一轮图片回答继续作答，不要假装重新看到了图片。"
            prompt += "\n不要要求用户重新上传图片。"
            prompt += "\n如果用户要求总结、概括、复述或确认，直接基于上一轮图片回答给出整理后的答案。"
            prompt += "\n如果仅根据上一轮图片回答无法确定，就明确说\"仅根据上一轮描述无法确定\"。"
            prompt += "\n直接回答问题，不要复述规则。"
            prompt += "\n输出 1 到 2 句完整的简体中文句子，必须自然收尾并以中文句号结束，不要只输出半句。"
        } else if LanguageService.shared.current.isJapanese {
            prompt += "\n\nあなたは同じ画像に関する追加質問への回答を続けています。"
            prompt += "\n下記に示す前のターンの画像への回答だけに基づいて続けて答え、画像を見直したふりをしないでください。"
            prompt += "\nユーザーに画像を再アップロードするよう求めないでください。"
            prompt += "\nユーザーが要約・概括・言い換え・確認を求めた場合は、前のターンの画像への回答からそのまま整理した答えを出してください。"
            prompt += "\n前のターンの画像への回答だけでは判断できない場合は、「前回の説明だけでは判断できません」とはっきり述べてください。"
            prompt += "\n質問に直接答え、ルールを復唱しないでください。"
            prompt += "\n完結した自然な日本語の文を1〜2文出力し、必ず自然に締めくくって句点で終え、文の途中で止めないでください。"
        } else {
            prompt += "\n\nYou are continuing to answer a follow-up question about the same image."
            prompt += "\nYou can only continue based on the previous image answer below; do not pretend to see the image again."
            prompt += "\nDo not ask the user to re-upload the image."
            prompt += "\nIf the user asks for a summary, paraphrase, restate, or confirmation, directly produce a tidy answer from the previous image response."
            prompt += "\nIf the previous image answer alone cannot determine the detail, explicitly say \"cannot determine from the previous description alone\"."
            prompt += "\nAnswer the question directly; do not repeat the rules."
            prompt += "\nOutput 1 to 2 complete English sentences, ending naturally with a period. Do not output only a partial sentence."
        }
        if enableThinking {
            prompt += "\n\n" + thinkingLanguageInstruction
        }
        prompt += "\n<turn|>\n"
        if LanguageService.shared.current.isChinese {
            prompt += """
            <|turn>user
            上一轮对图片的回答：
            \(clippedSummary)

            当前追问：
            \(userMessage)
            <turn|>
            <|turn>model
            """
        } else if LanguageService.shared.current.isJapanese {
            prompt += """
            <|turn>user
            前のターンでの画像への回答：
            \(clippedSummary)

            現在の追加質問：
            \(userMessage)
            <turn|>
            <|turn>model
            """
        } else {
            prompt += """
            <|turn>user
            Previous image answer:
            \(clippedSummary)

            Current follow-up:
            \(userMessage)
            <turn|>
            <|turn>model
            """
        }
        return prompt
    }

    static func buildImageFollowUpRepairPrompt(
        userMessage: String,
        assistantSummary: String,
        partialAnswer: String,
        systemPrompt: String? = nil,
        enableThinking: Bool = false
    ) -> String {
        let normalizedSummary = sanitizedAssistantHistoryContent(assistantSummary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedSummary: String
        if normalizedSummary.count > 280 {
            clippedSummary = String(normalizedSummary.prefix(280))
        } else {
            clippedSummary = normalizedSummary
        }

        let normalizedPartial = sanitizedAssistantHistoryContent(partialAnswer)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var prompt = "<|turn>system\n"
        if enableThinking {
            prompt += "<|think|>"
        }
        let basePrompt = (systemPrompt ?? defaultSystemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        prompt += basePrompt
        if LanguageService.shared.current.isChinese {
            prompt += "\n\n你只负责把一段未说完的图片追问回答，改写成 1 到 2 句完整、自然、简洁的简体中文。"
            prompt += "\n只能基于给出的上一轮图片回答补全，不要假装重新看到了图片。"
            prompt += "\n不要要求用户重新上传图片，不要解释规则，不要输出半句。"
            prompt += "\n严禁输出 <tool_call>、load_skill、JSON 或任何工具调用内容。"
            prompt += "\n如果信息仍然不足，就明确说\"仅根据上一轮图片回答无法确定\"。"
            prompt += "\n最终答案必须自然收尾并以中文句号结束。"
        } else if LanguageService.shared.current.isJapanese {
            prompt += "\n\nあなたは言いかけで終わった画像追加質問への回答を、完結した自然で簡潔な日本語1〜2文に書き換えるだけを担当します。"
            prompt += "\n与えられた前のターンの画像への回答だけに基づいて補完し、画像を見直したふりをしないでください。"
            prompt += "\nユーザーに画像を再アップロードするよう求めず、ルールを説明せず、文の途中で止めないでください。"
            prompt += "\n<tool_call>、load_skill、JSON、その他いかなるツール呼び出しの内容も絶対に出力しないでください。"
            prompt += "\n情報がまだ不足している場合は、「前のターンの画像への回答だけでは判断できません」とはっきり述べてください。"
            prompt += "\n最終的な答えは必ず自然に締めくくり、句点で終えてください。"
        } else {
            prompt += "\n\nYou only rewrite an incomplete image follow-up answer into 1 to 2 complete, natural, concise English sentences."
            prompt += "\nComplete the answer based only on the previous image answer provided; do not pretend to see the image again."
            prompt += "\nDo not ask the user to re-upload the image, do not explain rules, do not output a partial sentence."
            prompt += "\nStrictly do not emit <tool_call>, load_skill, JSON, or any tool invocation content."
            prompt += "\nIf information is still insufficient, explicitly say \"cannot determine from the previous image answer alone\"."
            prompt += "\nThe final answer must end naturally with a period."
        }
        if enableThinking {
            prompt += "\n\n" + thinkingLanguageInstruction
        }
        prompt += "\n<turn|>\n"
        if LanguageService.shared.current.isChinese {
            prompt += """
            <|turn>user
            上一轮对图片的回答：
            \(clippedSummary)

            当前追问：
            \(userMessage)

            回答草稿（可能未完成）：
            \(normalizedPartial)
            <turn|>
            <|turn>model
            """
        } else if LanguageService.shared.current.isJapanese {
            prompt += """
            <|turn>user
            前のターンでの画像への回答：
            \(clippedSummary)

            現在の追加質問：
            \(userMessage)

            回答の下書き（未完成の可能性あり）：
            \(normalizedPartial)
            <turn|>
            <|turn>model
            """
        } else {
            prompt += """
            <|turn>user
            Previous image answer:
            \(clippedSummary)

            Current follow-up:
            \(userMessage)

            Answer draft (possibly incomplete):
            \(normalizedPartial)
            <turn|>
            <|turn>model
            """
        }
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
        includeTimeAnchor: Bool = false,
        currentImageCount: Int = 0,
        forceResponse: Bool = false
    ) -> String {
        // Scaffold (T2 progressive disclosure):
        // 显式告诉模型当前 skill 有哪些工具可调 (只列名字, 不列 schema —
        // schema 属于 T3 暴露)。空列表时明确说"无工具", 防止模型幻觉编造
        // 不存在的工具名 (例如 "professional_translator")。
        let isZh = LanguageService.shared.current.isChinese
        let toolBlock: String
        if availableTools.isEmpty {
            toolBlock = isZh
            ? """
            当前 Skill **没有任何可调用的工具**。
            按 Skill 指令直接给最终答案正文文本, 禁止输出 <tool_call>。
            """
            : """
            This Skill **has no callable tools**.
            Follow the Skill instructions and give the final answer directly. Do not emit <tool_call>.
            """
        } else {
            let listText = availableTools.map { "- `\($0)`" }.joined(separator: "\n")
            toolBlock = isZh
            ? """
            当前 Skill 可调用的工具 (只允许这些名字):
            \(listText)
            如果需要操作, 输出 <tool_call>{"name": "<上面列表中的名字>", "arguments": {...}}</tool_call>。
            其他名字一律视为非法, 不要凭空编造。
            如果不需要工具, 直接给最终答案正文文本。
            """
            : """
            Callable tools for this Skill (only these names are allowed):
            \(listText)
            If action is needed, emit <tool_call>{"name": "<a name from the list above>", "arguments": {...}}</tool_call>.
            Any other name is illegal; do not fabricate.
            If no tools are needed, give the final answer directly.
            """
        }

        let systemBlock = extractSystemBlock(from: originalPrompt, includeTimeAnchor: includeTimeAnchor)
        let extraInstructions: String = isZh
            ? """
            对于当前这一个用户问题, 你已经加载了所需的 Skill 指令。不要再次调用 `load_skill`。

            已加载的 Skill 指令:
            \(skillInstructions)

            \(toolBlock)
            """
            : """
            For this user question, the required Skill instructions have been loaded. Do not call `load_skill` again.

            Loaded Skill instructions:
            \(skillInstructions)

            \(toolBlock)
            """
        let systemInstructions = injectIntoSystemBlock(systemBlock, extraInstructions: extraInstructions)

        var prompt = systemInstructions
        prompt += extractHistoryBlock(from: originalPrompt)
        if isZh {
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
        } else {
            prompt += """
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Handle this request per the Skill instructions above.
            - Do not call load_skill again.
            - Do not tell the user to "open a skill" or "use a capability".
            - Do not output intermediate thoughts, status updates, field names, JSON templates, code blocks, or planning drafts.
            \(forceResponse
              ? "You must output non-empty content: either a valid <tool_call>...</tool_call>, or the final answer."
              : "If no tools are needed, give the final answer directly; if tools are needed, invoke by one of the tool names listed above.")
            <turn|>
            <|turn>model

            """
        }
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

    /// Tool follow-up 的紧凑回答模式。
    ///
    /// 用在小上下文本地模型已经接近 token 上限，或工具结果天然较长（例如联网搜索）
    /// 的场景。这里刻意不带完整历史，只带用户当前问题和压缩后的工具结果，避免 R2
    /// 再次吃掉完整 R1 prompt/history。
    static func buildCompactToolAnswerPrompt(
        userQuestion: String,
        toolName: String,
        toolResultSummary: String,
        currentImageCount: Int = 0,
        enableThinking: Bool = false
    ) -> String {
        let result = compactToolResultSummary(
            toolResultSummary,
            maxCharacters: toolName == "web-search" ? 5_200 : 3_200
        )
        let toolSpecificInstructions = compactToolAnswerInstructions(toolName: toolName)
        let allowsFollowUpFetch = toolName == "web-search"
        if LanguageService.shared.current.isChinese {
            let thinkingPrefix = enableThinking ? "<|think|>" : ""
            let thinkingInstruction = enableThinking ? "\n\n\(thinkingLanguageInstruction)" : ""
            let answerOnlyRule: String
            let finalInstruction: String
            if allowsFollowUpFetch {
                answerOnlyRule = "你正在根据已经执行完成的 web-search 结果继续完成用户问题。如果结果已经足够，最终回答只输出答案；如果搜索结果明确提示需要读取原文且一个网页可以补全证据，只允许调用一次 web-fetch，不要再次调用 web-search 或其他工具。"
                finalInstruction = """
                如果需要读取原文, 只输出:
                <tool_call>{"name":"web-fetch","arguments":{"url":"https://example.com","max_characters":6000}}</tool_call>
                其中 url 必须替换为上方最相关的一条真实来源 URL。
                如果不需要继续读取, 请基于工具返回内容直接回答用户。
                直接回答时不要输出 JSON、字段名、模板、代码块或中间步骤。不要提到内部工具调用流程。
                """
            } else {
                answerOnlyRule = enableThinking
                    ? "你正在根据一个已经执行完成的工具结果回答用户。最终回答部分只输出答案，不要再次调用工具。"
                    : "你正在根据一个已经执行完成的工具结果回答用户。只输出最终答案，不要再次调用工具。"
                finalInstruction = """
                请基于工具返回内容直接回答用户。
                不要输出 JSON、字段名、模板、代码块或中间步骤。不要提到内部工具调用流程。
                """
            }
            return """
            <|turn>system
            \(thinkingPrefix)\(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            \(answerOnlyRule)
            回答必须简洁且可扫描：不要写成单段长文。简单事实问题先给直接答案，再补 1-2 条依据或限制；新闻、清单类问题逐条列出 3-6 个不同的事件/进展，每条一句话概括一个具体事件并尽量带日期，不要把多条新闻压成一条笼统结论；趋势、对比类才按主题归并；每条以短标签开头；只有在排行、对比、价格、参数、时间线明显适合时才用表格。
            如果是联网工具结果，证据相关性优先：只使用与用户问题直接相关的证据，忽略标记为“主题相关性低 / low query relevance”、confidence=low、首页/入口页或工具提示不能直接当作事实的条目。时效性用来排序而不是用来拒答：先给最新的相关条目并标注其发布时间（结果里已注明“发布时间”），从新到旧组织；如果没有严格落在用户时间窗口内的结果，如实说明“没有找到更新的，以下是检索到的最新内容”，仍然作答，不要拒答，也不要把旧内容谎称成当天。正文只写结论、关键事实和必要的不确定性，来源链接统一放到单独的“引用网址”段；不要把 URL/host 混在正文要点里。不要编造工具结果之外的信息。
            \(toolSpecificInstructions)\(thinkingInstruction)
            <turn|>
            <|turn>user
            用户问题：
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            工具 \(toolName) 返回：
            \(result)

            \(finalInstruction)
            <turn|>
            <|turn>model

            """
        } else if LanguageService.shared.current.isJapanese {
            let thinkingPrefix = enableThinking ? "<|think|>" : ""
            let thinkingInstruction = enableThinking ? "\n\n\(thinkingLanguageInstruction)" : ""
            let answerOnlyRule: String
            let finalInstruction: String
            if allowsFollowUpFetch {
                answerOnlyRule = "あなたは実行が完了した web-search の結果を使ってユーザーの質問を続けて仕上げています。結果がすでに十分なら、最終回答は答えだけを出力します；検索結果が原文の読み取りを明確に必要とし、1つのウェブページで根拠を補える場合のみ、web-fetch を1回だけ呼び出してよく、web-search やその他のツールを再度呼び出さないでください。"
                finalInstruction = """
                原文の読み取りが必要なら、次だけを出力:
                <tool_call>{"name":"web-fetch","arguments":{"url":"https://example.com","max_characters":6000}}</tool_call>
                ここで url は上記で最も関連する実在のソース URL に置き換えてください。
                これ以上読み取る必要がなければ、ツールが返した内容に基づいてユーザーに直接答えてください。
                直接答えるときは JSON・フィールド名・テンプレート・コードブロック・中間ステップを出力しないでください。内部のツール呼び出しの流れに言及しないでください。
                """
            } else {
                answerOnlyRule = enableThinking
                    ? "あなたは実行が完了したツール結果に基づいてユーザーに答えています。最終回答の部分では答えだけを出力し、ツールを再度呼び出さないでください。"
                    : "あなたは実行が完了したツール結果に基づいてユーザーに答えています。最終的な答えだけを出力し、ツールを再度呼び出さないでください。"
                finalInstruction = """
                ツールが返した内容に基づいてユーザーに直接答えてください。
                JSON・フィールド名・テンプレート・コードブロック・中間ステップを出力しないでください。内部のツール呼び出しの流れに言及しないでください。
                """
            }
            return """
            <|turn>system
            \(thinkingPrefix)\(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            \(answerOnlyRule)
            回答は必ず簡潔でスキャンしやすく：1段落の長文にしないでください。単純な事実の質問はまず直接の答えを出し、次に根拠や制限を1〜2点補います；ニュースやリスト類の質問は3〜6件の異なる出来事/進展を1件ずつ列挙し、各件は具体的な出来事を1文で要約しできるだけ日付を付け、複数のニュースを1つの漠然とした結論にまとめないでください；トレンド・比較類のみテーマでまとめ、各件は短いラベルで始めます；順位・比較・価格・仕様・時系列が明らかに適している場合のみ表を使います。
            ネット系ツールの結果の場合、根拠の関連性を優先します：ユーザーの質問に直接関連する根拠だけを使い、「主題相关性低 / low query relevance」と付いた項目・confidence=low・トップ/入口ページ・ツールが事実として直接扱えないと示す項目は無視します。時効性は並べ替えに使い、拒否には使いません：最新の関連項目を先に出してその発布時間を明記し（結果には既に「発布時間」が注記されています）、新しい順に整理します；ユーザーの期間に厳密に収まる結果がなければ、「より新しいものは見つかりませんでした、以下は検索できた最新の内容です」と正直に述べ、それでも答え、拒否せず、古い内容を当日のものと偽らないでください。本文には結論・重要な事実・必要な不確実性だけを書き、ソースのリンクは別立ての「引用 URL」段にまとめます；URL/host を本文の要点に混ぜないでください。ツール結果にない情報を捏造しないでください。
            \(toolSpecificInstructions)\(thinkingInstruction)
            <turn|>
            <|turn>user
            ユーザーの質問：
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            ツール \(toolName) の返答：
            \(result)

            \(finalInstruction)
            <turn|>
            <|turn>model

            """
        } else {
            let thinkingPrefix = enableThinking ? "<|think|>" : ""
            let thinkingInstruction = enableThinking ? "\n\n\(thinkingLanguageInstruction)" : ""
            let answerOnlyRule: String
            let finalInstruction: String
            if allowsFollowUpFetch {
                answerOnlyRule = "You are continuing from a completed web-search result. If the result is sufficient, output only the final answer. If the search result explicitly needs page text and one webpage can complete the evidence, you may call web-fetch once; do not call web-search or any other tool again."
                finalInstruction = """
                If you need to read the page, output only:
                <tool_call>{"name":"web-fetch","arguments":{"url":"https://example.com","max_characters":6000}}</tool_call>
                Replace url with the most relevant real source URL from the results above.
                If no further fetch is needed, answer the user directly from the tool result.
                In direct answers, do not output JSON, field names, templates, code blocks, or intermediate steps. Do not mention internal tool-calling flow.
                """
            } else {
                answerOnlyRule = enableThinking
                    ? "You are answering from a completed tool result. In the final answer section, output only the answer; do not call tools again."
                    : "You are answering from a completed tool result. Output only the final answer; do not call tools again."
                finalInstruction = """
                Answer the user directly based on the tool result.
                Do not output JSON, field names, templates, code blocks, or intermediate steps. Do not mention internal tool-calling flow.
                """
            }
            return """
            <|turn>system
            \(thinkingPrefix)\(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            \(answerOnlyRule)
            Keep the answer concise and scannable; do not write one long paragraph. For a simple factual question, give the direct answer first, then 1-2 supporting or caveat bullets. For news or list-style questions, enumerate 3-6 distinct events/items, each a one-line summary of a specific event with its date where available — do not collapse multiple news items into one vague conclusion. Group by theme only for trend or comparison questions. Start each bullet with a short label. Use a table only when ranking, comparison, pricing, specifications, or timeline data clearly benefits from it.
            For web tool results, relevance gates and recency orders: use only evidence directly relevant to the user's question, ignoring items marked “low query relevance”, confidence=low, homepage/index, or otherwise not directly usable as facts. Use recency to order, not to refuse: lead with the freshest relevant items and state each item's publish date (results already annotate “Published”), organizing newest-first; if nothing strictly inside the requested window was found, say plainly “nothing more recent was found; here is the latest available,” still answer, and never claim stale items are same-day. Keep the body focused on the conclusion, key facts, and necessary uncertainty, and put source links in a separate “Sources” section; do not mix URLs/hosts into the body bullets. Do not invent facts beyond the tool result.
            \(toolSpecificInstructions)\(thinkingInstruction)
            <turn|>
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Tool \(toolName) returned:
            \(result)

            \(finalInstruction)
            <turn|>
            <|turn>model

            """
        }
    }

    private static func compactToolAnswerInstructions(toolName: String) -> String {
        switch toolName {
        case "web-search":
            return tr(
                "对 web-search：优先查看 evidence_pack，并看每条结果的“发布时间 / published_at / age_days”。若 evidence_pack.sufficiency=sufficient 或 answerability=direct，基于 evidence_pack.chunks / 可直接使用的搜索条目回答。可直接使用的条目需满足：query_relevant 不是 false、confidence 不是 low、不是首页/入口页、没有标记“主题相关性低 / low query relevance”。时效性用于排序而不是拒答：按发布时间从新到旧组织，先给最新的相关条目并标注其发布时间；如果最新的也比用户要求的时间窗口旧，如实说明“没有找到严格满足时间约束的，以下是检索到的最新内容”，仍然照常作答，不要拒答，也不要把旧内容谎称成当天。只有在确实没有任何相关结果时，才说明这次搜索没有返回可用结果。直接回答必须分成两段：先写“总结”，再写“引用网址”。必须全程使用当前会话语言回答，即使来源页面是其他语言。“总结”段必须是可扫描的结构化 Markdown，不要写成单段长文；只写结论、关键数值、主题化要点和必要的不确定性，不要夹 URL、host、来源括号或搜索时间；新闻/快讯类要逐条列出 3-6 个不同的事件，每条一句话概括一个具体事件并带上日期，不要把多条新闻压成一条笼统结论；趋势/对比类才按主题归并，优先用 `- 标签：事实/影响` 形式；简单事实问题第一句先给直接答案。“引用网址”段列出 1-5 条支撑结论的 Markdown 链接，优先使用 evidence_pack.chunks 里的真实 URL，同源去重，较新的来源排前面。若用户问具体数值、价格、汇率、比分或“多少”，总结第一句先给证据里的具体数值。若 answerability=needs_fetch 且 evidence_pack 为空或偏薄，才选择最相关 URL 调用一次 web-fetch。不要把首页、频道页、站点简介、低置信或低相关条目当作事实。",
                "For web-search: inspect evidence_pack first, and check each result's “Published / published_at / age_days.” If evidence_pack.sufficiency=sufficient or answerability=direct, answer from evidence_pack.chunks / directly usable search entries. A directly usable entry must have query_relevant not false, confidence not low, not be homepage/index, and not be marked “low query relevance.” Use recency to order, not to refuse: organize newest-first, lead with the freshest relevant items and state each item's publish date; if even the freshest is older than the user's requested window, say plainly “nothing strictly within the time constraint was found; here is the latest available,” still answer as usual, do not refuse, and never claim stale items are same-day. Only when there is genuinely no relevant result at all, say the search returned no usable results. Direct answers must use two sections: “Summary” first, then “Sources.” Write the entire answer in the current conversation language, even if sources use another language. The Summary section must be scannable structured Markdown, not one long paragraph; include only the conclusion, key values, themed bullets, and necessary uncertainty, with no URLs, hosts, inline source parentheticals, or search timestamps. For news, enumerate 3-6 distinct events, each a one-line summary of a specific event with its date, without collapsing them into one vague conclusion; group by theme only for trends/comparisons, preferring `- Label: fact/implication` bullets. For a simple factual question, put the direct answer first. The Sources section must list 1-5 supporting Markdown links, preferring real URLs from evidence_pack.chunks, deduplicating by source, with fresher sources first. If the user asks for a concrete value, price, exchange rate, score, or “how much/how many,” the first Summary sentence must give the concrete value from evidence. If answerability=needs_fetch and the evidence_pack is empty or thin, choose the most relevant URL and call web-fetch once. Do not treat homepages, category pages, site descriptions, low-confidence, or low-relevance entries as facts.",
                "web-search について：まず evidence_pack を確認し、各結果の「発布時間 / published_at / age_days」を見ます。evidence_pack.sufficiency=sufficient または answerability=direct なら、evidence_pack.chunks／そのまま使える検索項目に基づいて答えます。そのまま使える項目の条件：query_relevant が false でない、confidence が low でない、トップ/入口ページでない、「主題相关性低 / low query relevance」と付いていないこと。時効性は並べ替えに使い、拒否には使いません：発布時間の新しい順に整理し、最新の関連項目を先に出してその発布時間を明記します；最新のものでもユーザーが求めた期間より古い場合は、「時間条件を厳密に満たすものは見つかりませんでした、以下は検索できた最新の内容です」と正直に述べ、通常どおり答え、拒否せず、古い内容を当日のものと偽らないでください。本当に関連する結果が一つもない場合のみ、今回の検索では使える結果が返らなかったと述べます。直接回答する場合は必ず2つの段落に分けます：先に「総結」、次に「引用 URL」。たとえソースのページが他言語でも、回答は全編にわたり現在の会話の言語で書いてください。「総結」段はスキャンしやすい構造化された Markdown にし、1段落の長文にしないでください；結論・重要な数値・テーマ別の要点・必要な不確実性だけを書き、URL・host・ソースのかっこ書き・検索時刻は混ぜないでください；ニュース/速報類は3〜6件の異なる出来事を1件ずつ列挙し、各件は具体的な出来事を1文で要約し日付を付け、複数のニュースを1つの漠然とした結論にまとめないでください；トレンド/比較類のみテーマでまとめ、`- ラベル：事実/影響` の形式を優先します；単純な事実の質問は最初の1文でまず直接の答えを出します。「引用 URL」段は結論を裏づける Markdown リンクを1〜5件挙げ、evidence_pack.chunks 内の実在する URL を優先し、同一ソースは重複排除し、新しいソースを前に並べます。ユーザーが具体的な数値・価格・為替・スコア・「いくつ/いくら」を尋ねた場合、総結の最初の1文で根拠にある具体的な数値をまず出します。answerability=needs_fetch かつ evidence_pack が空または薄い場合のみ、最も関連する URL を選んで web-fetch を1回だけ呼び出します。トップページ・チャンネルページ・サイト紹介・低 confidence・低関連の項目を事実として扱わないでください。"
            )
        case "web-fetch":
            return tr(
                "对 web-fetch：只使用已读取网页正文回答。必须全程使用当前会话语言回答，即使网页正文是其他语言。若正文包含按时间、排行或列表排列的数据，选最相关/最新的一条直接给结论；不要因为页面没有写“绝对最新”就空泛拒答。直接回答同样分成“总结”和“引用网址”，“总结”必须可扫描、结构化，不要写成单段长文；来源只放在“引用网址”段。只有正文确实没有覆盖用户问题时，才明确说明页面中没有找到对应信息。",
                "For web-fetch: answer only from the fetched page text. Write the entire answer in the current conversation language, even if the page text uses another language. If the text contains dated, ranked, or listed data, choose the most relevant/latest entry and give the conclusion; do not refuse just because the page does not explicitly label it as “absolute latest.” Direct answers should also use “Summary” and “Sources”; the Summary must be scannable and structured, not one long paragraph, with source links only in Sources. Only say the requested information was not found when the page text truly does not cover the user question.",
                "web-fetch について：読み取ったページ本文だけに基づいて答えます。たとえページ本文が他言語でも、回答は全編にわたり現在の会話の言語で書いてください。本文に時間・順位・リスト順に並んだデータが含まれる場合は、最も関連する/最新の1件を選んで結論を出します；ページに「絶対的な最新」と書いていないという理由で漠然と拒否しないでください。直接回答も同様に「総結」と「引用 URL」に分け、「総結」はスキャンしやすく構造化し、1段落の長文にしないでください；ソースは「引用 URL」段にのみ置きます。本文が本当にユーザーの質問をカバーしていない場合のみ、ページ内に該当する情報が見つからなかったとはっきり述べてください。"
            )
        default:
            return ""
        }
    }

    static func buildWebQueryPlanPrompt(
        userQuestion: String,
        initialQuery: String,
        currentImageCount: Int = 0
    ) -> String {
        if LanguageService.shared.current.isChinese {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            你是联网搜索查询规划器。你的任务是把用户问题改写成 2-4 条适合搜索引擎的查询词。
            规则:
            - 只输出 JSON 对象，不要解释、不要 Markdown、不要调用工具。
            - JSON schema: {"queries":["..."],"freshness":"current|recent|static|unspecified"}
            - queries 必须保留用户的主体、地点、时间范围、比较条件和语言偏好。
            - 时效性问题(实时/今天/最近/价格/汇率/天气/新闻/比赛/政策/版本等变化信息)用 freshness=current 或 recent 表达。
            - 时效只放进 freshness 字段；查询词保持主题词本身，不要塞入绝对日期或"今天/现在"这类时间词(检索端会按 freshness 自动做时间过滤；查询词里出现"2026年6月6日"这类日期反而会匹配到日历/年份/赛程等无关页)。
            - 不要凭空添加用户没问的实体、城市、品牌、日期或网站名。
            - 每条 query 控制在 6-20 个词或 4-40 个中文字符，避免完整句子。
            <turn|>
            <|turn>user
            用户问题:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            初始查询:
            \(initialQuery)
            <turn|>
            <|turn>model

            """
        } else if LanguageService.shared.current.isJapanese {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            あなたはネット検索クエリのプランナーです。ユーザーの質問を検索エンジン向けの2〜4件のクエリ語に書き換えるのが任務です。
            ルール:
            - JSON オブジェクトだけを出力し、説明・Markdown・ツール呼び出しはしないでください。
            - JSON schema: {"queries":["..."],"freshness":"current|recent|static|unspecified"}
            - queries にはユーザーの主体・場所・期間・比較条件・言語の好みを必ず残してください。
            - 時効性のある質問（リアルタイム/今日/最近/価格/為替/天気/ニュース/試合/政策/バージョンなど変化する情報）は freshness=current または recent で表します。
            - 時効性は freshness フィールドにだけ入れます；クエリ語は主題語そのものを保ち、絶対日付や「今日/今」のような時間語を入れないでください（検索側が freshness に従って自動で時間フィルタをかけます；クエリ語に「2026年6月6日」のような日付があると、かえってカレンダー/年/日程などの無関係なページにマッチします）。
            - ユーザーが尋ねていない実体・都市・ブランド・日付・サイト名を勝手に追加しないでください。
            - 各 query は6〜20語または4〜40文字に収め、完全な文は避けてください。
            <turn|>
            <|turn>user
            ユーザーの質問:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            初期クエリ:
            \(initialQuery)
            <turn|>
            <|turn>model

            """
        } else {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            You are a web-search query planner. Rewrite the user question into 2-4 search-engine queries.
            Rules:
            - Output only one JSON object. No explanation, Markdown, or tool calls.
            - JSON schema: {"queries":["..."],"freshness":"current|recent|static|unspecified"}
            - queries must preserve the subject, location, time range, comparison constraints, and language preference.
            - For time-sensitive questions (live/current/recent prices, exchange rates, weather, news, sports, policy, versions, etc.), express recency via the freshness field (current or recent).
            - Put recency ONLY in the freshness field; keep the queries to the topic itself and do not inject absolute dates or words like "today/now" (the retriever applies a time filter from freshness automatically; a date like "June 6 2026" in the query text matches irrelevant calendar/year/schedule pages).
            - Do not add entities, cities, brands, dates, or websites the user did not ask for.
            - Keep each query concise, about 4-14 words.
            <turn|>
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Initial query:
            \(initialQuery)
            <turn|>
            <|turn>model

            """
        }
    }

    static func buildWebQueryReplanPrompt(
        userQuestion: String,
        previousSearchSummary: String,
        currentImageCount: Int = 0
    ) -> String {
        let summary = compactToolResultSummary(previousSearchSummary, maxCharacters: 4_200)
        if LanguageService.shared.current.isChinese {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            你是联网搜索二次查询规划器。上一轮搜索证据不足，你需要基于失败信息重新生成 2-4 条不同的搜索 query。
            规则:
            - 只输出 JSON 对象，不要解释、不要 Markdown、不要调用工具。
            - JSON schema: {"queries":["..."],"reason":"..."}
            - 新 queries 必须保留用户原始问题的主体、地点、时间范围和约束。
            - 避免重复上一轮 query；换用同义表达、英文/中文变体、官方/数据源表达、具体实体名或更窄条件。
            - 不要凭空添加用户没问的实体、城市、品牌、日期或网站名。
            - 每条 query 控制在 6-20 个词或 4-40 个中文字符。
            <turn|>
            <|turn>user
            用户问题:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            上一轮搜索摘要:
            \(summary)
            <turn|>
            <|turn>model

            """
        } else if LanguageService.shared.current.isJapanese {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            あなたはネット検索の二次クエリプランナーです。前回の検索では根拠が不足したため、失敗の情報を踏まえて2〜4件の異なる検索 query を作り直してください。
            ルール:
            - JSON オブジェクトだけを出力し、説明・Markdown・ツール呼び出しはしないでください。
            - JSON schema: {"queries":["..."],"reason":"..."}
            - 新しい queries にはユーザーの元の質問の主体・場所・期間・制約を必ず残してください。
            - 前回の query の繰り返しを避け、同義表現・英語/中国語の言い換え・公式/データソースの表現・具体的な実体名・より狭い条件に切り替えてください。
            - ユーザーが尋ねていない実体・都市・ブランド・日付・サイト名を勝手に追加しないでください。
            - 各 query は6〜20語または4〜40文字に収めてください。
            <turn|>
            <|turn>user
            ユーザーの質問:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            前回の検索の要約:
            \(summary)
            <turn|>
            <|turn>model

            """
        } else {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            You are a second-pass web-search query planner. The previous search produced insufficient evidence. Generate 2-4 different search queries.
            Rules:
            - Output only one JSON object. No explanation, Markdown, or tool calls.
            - JSON schema: {"queries":["..."],"reason":"..."}
            - New queries must preserve the user's original subject, location, time range, and constraints.
            - Avoid repeating previous queries; use synonyms, language variants, official/data-source wording, specific entity names, or narrower constraints.
            - Do not add entities, cities, brands, dates, or websites the user did not ask for.
            - Keep each query concise, about 4-14 words.
            <turn|>
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Previous search summary:
            \(summary)
            <turn|>
            <|turn>model

            """
        }
    }

    /// Model-driven evidence curation (the SourceCurator step of a mature search
    /// agent): the model reads the candidate sources and extracts only the facts
    /// that answer the question, verbatim values preserved, irrelevant sources
    /// dropped. This replaces hand-tuned heuristic ranking — the model judges
    /// relevance and pulls the answer, so it generalizes to any domain. Output is
    /// an intermediate fact digest, not the user-facing answer.
    static func buildWebCurationPrompt(
        userQuestion: String,
        candidates: String,
        currentImageCount: Int
    ) -> String {
        if LanguageService.shared.current.isChinese {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            你正在从联网搜索返回的多个来源里，抽取能回答用户问题的事实。只依据下面的来源材料，不要补充材料之外的任何信息，也不要现在写最终回答。
            输出要求：
            - 逐条列出与用户问题直接相关的具体事实，每条一句话，句末标注来源编号，如 [来源2]。
            - 必须原样保留具体数值和日期（价格、汇率、比分、温度、百分比、时间等），不要四舍五入或改写成“约/大概”。
            - 不同来源数值不一致时，分别列出并各自标注来源；同一事实多个来源印证可合并标注。
            - 跳过与问题无关的来源（如球队名单、导航栏、广告、词条释义、与问题主体无关的旧内容），不要为它们写条目。
            - 若所有来源都没有能回答问题的事实，只输出一行：无相关事实。
            - 不要写“总结/引用网址”等小标题，不要客套，只输出事实清单。
            <turn|>
            <|turn>user
            用户问题：
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            来源材料：
            \(candidates)

            请只输出相关事实清单。
            <turn|>
            <|turn>model

            """
        } else if LanguageService.shared.current.isJapanese {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            あなたはネット検索が返した複数のソースから、ユーザーの質問に答えられる事実を抽出しています。下記のソース資料だけに基づき、資料外の情報は一切補わず、今は最終回答を書かないでください。
            出力の要件：
            - ユーザーの質問に直接関連する具体的な事実を1件ずつ列挙し、各件は1文で、文末にソース番号を付けます（例: [来源2]）。
            - 具体的な数値と日付（価格・為替・スコア・気温・パーセント・時刻など）はそのまま残し、四捨五入したり「約/おおよそ」に書き換えたりしないでください。
            - ソースごとに数値が食い違う場合は別々に列挙し各自のソースを付けます；同じ事実を複数のソースが裏づける場合はソースをまとめて付けてもかまいません。
            - 質問に無関係なソース（チームの名簿・ナビゲーションバー・広告・用語の定義・質問の主体と関係のない古い内容など）は飛ばし、それらの項目は書かないでください。
            - どのソースにも質問に答えられる事実がない場合は、1行だけ出力: NO RELEVANT FACTS。
            - 「総結/引用 URL」などの小見出しは書かず、社交辞令も書かず、事実の一覧だけを出力してください。
            <turn|>
            <|turn>user
            ユーザーの質問：
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            ソース資料：
            \(candidates)

            関連する事実の一覧だけを出力してください。
            <turn|>
            <|turn>model

            """
        } else {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            You are extracting the facts that answer the user's question from several web sources. Use only the source material below; add nothing beyond it, and do not write the final answer yet.
            Output rules:
            - List each fact directly relevant to the question on its own line, one sentence, ending with its source tag, e.g. [source2].
            - Preserve concrete values and dates verbatim (prices, exchange rates, scores, temperatures, percentages, times); do not round or soften to "about/around".
            - When sources disagree on a value, list each separately with its own tag; when several sources confirm the same fact, you may merge tags.
            - Skip sources irrelevant to the question (rosters, nav bars, ads, dictionary definitions, stale content unrelated to the subject); write no line for them.
            - If no source contains a fact that answers the question, output exactly one line: NO RELEVANT FACTS.
            - Do not write "Summary/Sources" headings or pleasantries; output only the fact list.
            <turn|>
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Source material:
            \(candidates)

            Output only the list of relevant facts.
            <turn|>
            <|turn>model

            """
        }
    }

    static func buildWebAnswerRepairPrompt(
        userQuestion: String,
        toolName: String,
        toolResultSummary: String,
        draftAnswer: String,
        validationIssues: [String],
        currentImageCount: Int = 0
    ) -> String {
        let result = compactToolResultSummary(toolResultSummary, maxCharacters: 5_200)
        let draft = compactToolResultSummary(draftAnswer, maxCharacters: 1_600)
        let issues = validationIssues.isEmpty
            ? tr("输出格式或证据约束不稳定。", "The output format or evidence grounding is unstable.", "出力形式または根拠の制約が安定していません。")
            : validationIssues.map { "- \($0)" }.joined(separator: "\n")

        if LanguageService.shared.current.isChinese {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            你正在修复一个联网搜索回答。只允许基于下面的工具结果重写最终答案；不要调用工具；不要补充工具结果之外的信息。
            输出契约:
            - 必须包含“总结”和“引用网址”两个段落。
            - 必须全程使用中文回答，即使来源页面是英文或其他语言。
            - 相关性优先于格式：忽略 query_relevant=false、标记“主题相关性低”、confidence=low、首页/入口页或不能直接当作事实的条目，不要为了填充结构而总结无关结果。
            - 时效性用于排序而不是拒答：先给最新的相关条目并标注其发布时间，从新到旧组织。
            - “总结”必须是可扫描的结构化 Markdown，不要写成单段长文；只写结论、关键数值、主题化要点和必要的不确定性；不要放 URL、host、来源括号、搜索时间或内部流程。
            - 简单事实问题先给直接答案；新闻、趋势、对比、清单类问题用 3-6 条带短标签的要点；只有排行、对比、价格、参数或时间线明显适合时才用表格。
            - “引用网址”只列相关来源的 Markdown 链接，例如: 1. [站点名](https://example.com)。
            - 如果没有严格满足时间窗口的结果，就如实说明“没有找到更新的，以下是检索到的最新内容”，仍然给出最新的相关条目并标注日期；只有完全没有相关结果时才说证据不足。不要编造，也不要把旧内容谎称成当天。
            <turn|>
            <|turn>user
            用户问题：
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            工具 \(toolName) 返回：
            \(result)

            待修复回答：
            \(draft)

            需要修复的问题：
            \(issues)

            请只输出修复后的最终答案。
            <turn|>
            <|turn>model

            """
        } else if LanguageService.shared.current.isJapanese {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            あなたはネット検索に基づく回答を修復しています。下記のツール結果だけに基づいて最終回答を書き直してください；ツールを呼び出さず；ツール結果外の情報を補わないでください。
            出力の契約:
            - 「総結」と「引用 URL」の2つの段落を必ず含めてください。
            - たとえソースが英語や他言語でも、回答は全編にわたり日本語で書いてください。
            - 関連性は形式に優先します：query_relevant=false・「主題相关性低」の表示・confidence=low・トップ/入口ページ・事実として直接使えない項目は無視し、構造を埋めるために無関係な結果を要約しないでください。
            - 時効性は並べ替えに使い、拒否には使いません：最新の関連項目を先に出してその発布時間を明記し、新しい順に整理します。
            - 「総結」はスキャンしやすい構造化された Markdown にし、1段落の長文にしないでください；結論・重要な数値・テーマ別の要点・必要な不確実性だけを書き；URL・host・ソースのかっこ書き・検索時刻・内部の流れは置かないでください。
            - 単純な事実の質問はまず直接の答えを出します；ニュース・トレンド・比較・リスト類の質問は短いラベル付きの要点を3〜6件使います；順位・比較・価格・仕様・時系列が明らかに適している場合のみ表を使います。
            - 「引用 URL」には関連するソースの Markdown リンクだけを並べます、例: 1. [サイト名](https://example.com)。
            - 時間条件を厳密に満たす結果がなければ、「より新しいものは見つかりませんでした、以下は検索できた最新の内容です」と正直に述べ、それでも最新の関連項目を日付付きで示します；関連する結果が全くない場合のみ根拠不足と述べます。捏造せず、古い内容を当日のものと偽らないでください。
            <turn|>
            <|turn>user
            ユーザーの質問：
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            ツール \(toolName) の返答：
            \(result)

            修復対象の回答：
            \(draft)

            修復が必要な問題：
            \(issues)

            修復後の最終回答だけを出力してください。
            <turn|>
            <|turn>model

            """
        } else {
            return """
            <|turn>system
            \(defaultSystemPrompt)
            \(currentTimeAnchorBlock())
            You are repairing a web-grounded answer. Rewrite the final answer using only the tool result below; do not call tools; do not add facts beyond the tool result.
            Output contract:
            - Include exactly two visible sections: “Summary” and “Sources.”
            - Write the entire answer in English, even if some sources are Chinese or another language.
            - Relevance comes before format: ignore entries with query_relevant=false, low query relevance, confidence=low, homepage/index, or entries that cannot be used directly as facts; do not summarize unrelated results just to fill structure.
            - Recency orders, it does not refuse: lead with the freshest relevant items and state each item's publish date, organizing newest-first.
            - “Summary” must be scannable structured Markdown, not one long paragraph; include only the conclusion, key values, themed bullets, and necessary uncertainty; no URLs, hosts, inline source parentheses, search timestamps, or internal process.
            - For simple factual questions, give the direct answer first. For news, trends, comparisons, or lists, use 3-6 short labeled bullets. Use a table only when ranking, comparison, pricing, specifications, or timeline data clearly benefits from it.
            - “Sources” contains relevant-source Markdown links only, for example: 1. [site](https://example.com).
            - If nothing strictly within the time window was found, say plainly “nothing more recent was found; here is the latest available” and still give the freshest relevant items with their dates; only say evidence is insufficient when there is no relevant result at all. Do not invent, and never claim stale items are same-day.
            <turn|>
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Tool \(toolName) returned:
            \(result)

            Draft answer:
            \(draft)

            Issues to fix:
            \(issues)

            Output only the repaired final answer.
            <turn|>
            <|turn>model

            """
        }
    }

    private static func compactToolResultSummary(
        _ summary: String,
        maxCharacters: Int = 3200
    ) -> String {
        let normalized = summary
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else {
            return normalized
        }

        let clipped = String(normalized.prefix(maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LanguageService.shared.current.isChinese
            ? "\(clipped)\n\n（工具结果较长，以上为截断后的可用部分。）"
            : "\(clipped)\n\n(Tool result was long; the usable portion above was truncated.)"
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
        // zh / en 两套 system + user block, 保持结构完全对齐。
        // 中文系统下字节相同于原模板 (保证 E2B/E4B 路径不 regress);
        // 英文系统下用英文模板, 否则用户调用工具后模型会被中文尾缀拉回中文。
        let leanSystemBlock: String
        let userBlock: String
        if LanguageService.shared.current.isChinese {
            leanSystemBlock = """
            <|turn>system
            \(defaultSystemPrompt) 回答跟随用户输入的语言, 简洁实用.
            <turn|>

            """
            userBlock = """
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
        } else if LanguageService.shared.current.isJapanese {
            leanSystemBlock = """
            <|turn>system
            \(defaultSystemPrompt) 回答はユーザーが入力した言語に合わせ、簡潔で実用的に.
            <turn|>

            """
            userBlock = """
            <|turn>user
            ユーザーの元の質問：
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            ツール \(toolName) は実行が完了しました。
            ユーザーにそのまま渡せる結果：
            \(toolResultSummary)

            以上の結果に基づいてユーザーに直接答えてください。
            上記の内容がすでに完全な答えなら、最小限の整理だけにとどめてよいですが、重要な情報を漏らさないでください。
            ツールを再度呼び出さず、聞き返さず、ツール名・Skill・status・result・arguments などのフィールドに言及しないでください。
            Markdown のコードブロックも、JSON・キー名・テンプレート・中間ステップも出力しないでください。
            空白を出力しないでください。
            <turn|>
            <|turn>model

            """
        } else {
            leanSystemBlock = """
            <|turn>system
            \(defaultSystemPrompt) Reply in the same language the user used, concise and practical.
            <turn|>

            """
            userBlock = """
            <|turn>user
            Original user question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Tool \(toolName) has finished executing.
            Result you can give to the user directly:
            \(toolResultSummary)

            Answer the user directly based on the result above.
            If the content above is already a complete answer, you may do minimal tidying, but do not drop key information.
            Do not call tools again, do not ask clarifying questions, do not mention tool names, Skill, status, result, arguments, or any other internal field.
            Do not output Markdown code blocks, JSON, key names, templates, or intermediate steps.
            Do not output empty content.
            <turn|>
            <|turn>model

            """
        }

        return leanSystemBlock + extractHistoryBlock(from: originalPrompt) + userBlock
    }

    /// 单 Skill + 单工具时，先只让模型抽取 arguments，避免它直接续写出半截
    /// `<tool_call>` 或字段草稿。
    static func buildSingleToolArgumentsPrompt(
        originalPrompt: String,
        userQuestion: String,
        skillInstructions: String,
        toolName: String,
        toolParameters: String,
        includeTimeAnchor: Bool = false,
        currentImageCount: Int = 0
    ) -> String {
        let isZh = LanguageService.shared.current.isChinese
        let systemBlock = extractSystemBlock(from: originalPrompt, includeTimeAnchor: includeTimeAnchor)
        let extraInstructions: String = isZh
            ? """
            对于当前这一个用户问题，你已经加载了所需的 Skill 指令。
            不要再次调用 `load_skill`。

            已加载的 Skill 指令：
            \(skillInstructions)
            """
            : """
            For this user question, the required Skill instructions have been loaded.
            Do not call `load_skill` again.

            Loaded Skill instructions:
            \(skillInstructions)
            """
        let systemInstructions = injectIntoSystemBlock(systemBlock, extraInstructions: extraInstructions)

        let userBlock: String = isZh
            ? """
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
            4. 可选字段如果没有，就直接省略。tool 参数说明里标"可选"的字段不算必填.
            5. 时间字段必须转换成 ISO 8601，例如 `2026-04-07T20:00:00`。
            6. 只有用户原话完全没说某个必填参数, 才输出 _needs_clarification 字段+一句具体追问.
               绝大多数情况应该直接给 arguments, 不要轻易追问. 可选字段缺失绝不追问.
            <turn|>
            <|turn>model

            """
            : """
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Your only job is to extract arguments for tool `\(toolName)`.
            Parameter spec:
            \(toolParameters)

            Strictly follow these rules:
            1. Do not invoke tools; do not emit `<tool_call>`.
            2. Output ONE JSON object, the arguments themselves.
            3. Do not output Markdown, code blocks, explanations, field drafts, or extra text.
            4. Omit optional fields if not present. Fields marked "optional" in the spec are not required.
            5. Time fields must be converted to ISO 8601, e.g. `2026-04-07T20:00:00`.
            6. Only if the user's literal words did not provide a required parameter, output a `_needs_clarification` field with one specific follow-up question.
               In most cases, give the arguments directly; do not ask clarifying questions. Never ask about missing optional fields.
            <turn|>
            <|turn>model

            """

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + userBlock
    }

    /// 单 Skill + 多工具时，让模型只在允许的工具集合中选择一个工具并抽取 arguments。
    static func buildSkillToolSelectionPrompt(
        originalPrompt: String,
        userQuestion: String,
        skillInstructions: String,
        allowedToolsSummary: String,
        includeTimeAnchor: Bool = false,
        currentImageCount: Int = 0
    ) -> String {
        let isZh = LanguageService.shared.current.isChinese
        let systemBlock = extractSystemBlock(from: originalPrompt, includeTimeAnchor: includeTimeAnchor)
        let extraInstructions: String = isZh
            ? """
            对于当前这一个用户问题，你已经加载了所需的 Skill 指令。
            不要再次调用 `load_skill`。

            已加载的 Skill 指令：
            \(skillInstructions)
            """
            : """
            For this user question, the required Skill instructions have been loaded.
            Do not call `load_skill` again.

            Loaded Skill instructions:
            \(skillInstructions)
            """
        let systemInstructions = injectIntoSystemBlock(systemBlock, extraInstructions: extraInstructions)

        let userBlock: String = isZh
            ? """
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
            7. 只有用户原话完全没说某个执行必需的信息, 才输出 _needs_clarification 字段+一句具体追问.
               绝大多数情况直接给 name+arguments, 不要轻易追问.
            <turn|>
            <|turn>model

            """
            : """
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            You are doing only two things:
            1. Pick the most appropriate one from the allowed tools below
            2. Extract arguments for that tool

            Allowed tools:
            \(allowedToolsSummary)

            Strictly follow these rules:
            1. Do not invoke tools; do not emit `<tool_call>`.
            2. Output ONE JSON object, format must be:
               {"name":"<tool_name>","arguments":{"<param>":"<value>"}}
            3. `name` must be one of the allowed tools above.
            4. Keep only the parameters this tool needs in `arguments`; omit missing optional ones.
            5. Do not output Markdown, code blocks, explanations, drafts, or extra text.
            6. Time fields must be converted to ISO 8601, e.g. `2026-04-07T20:00:00`.
            7. Only if the user's literal words omitted something required for execution, output a `_needs_clarification` field with one specific follow-up question.
               In most cases, give name+arguments directly; do not ask lightly.
            <turn|>
            <|turn>model

            """

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + userBlock
    }

    // MARK: - Planner v3 Prompt Builders

    static func buildSkillSelectionPrompt(
        originalPrompt: String,
        userQuestion: String,
        availableSkillsSummary: String,
        recentContextSummary: String = "",
        currentImageCount: Int = 0
    ) -> String {
        let isZh = LanguageService.shared.current.isChinese
        let systemBlock = extractSystemBlock(from: originalPrompt)
        let extraInstructions: String = isZh
            ? """
            对于当前这一个用户问题，你现在只负责判断需要哪些 Skill。
            不要调用 `load_skill`，不要输出 `<tool_call>`，不要直接回答用户问题。

            可用的 Skill 与工具如下：
            \(availableSkillsSummary)
            """
            : """
            For this user question, your only job is to decide which Skills are needed.
            Do not call `load_skill`, do not emit `<tool_call>`, do not answer the user directly.

            Available Skills and tools:
            \(availableSkillsSummary)
            """
        let systemInstructions = injectIntoSystemBlock(systemBlock, extraInstructions: extraInstructions)

        let recentContextBlock: String
        if recentContextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recentContextBlock = ""
        } else {
            recentContextBlock = isZh
                ? """

                最近已知的工具结果摘要（可作为当前规划的上下文）：
                \(recentContextSummary)
                """
                : """

                Recent known tool-result summary (as context for planning):
                \(recentContextSummary)
                """
        }

        let userBlock: String = isZh
            ? """
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
            6. 如果完全无法判断, 返回 required_skills 为空数组, 同时把 needs_clarification 字段
               填成一句具体追问 (用一句中文陈述需要追问什么, 不要复读本规则的字面文本).
            <turn|>
            <|turn>model

            """
            : """
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))\(recentContextBlock)

            Output ONE JSON object, format must be:
            {
              "required_skills": ["skill_id_1", "skill_id_2"],
              "needs_clarification": null
            }

            Strictly follow these rules:
            1. Output only the JSON object — no Markdown, no code blocks, no explanations, no extra text.
            2. Each item in `required_skills` must be exactly one of the skill id strings listed under "Available Skills and tools" above — not a tool name, not concatenated, not translated.
            3. If the task requires first getting a result and then passing it to another Skill, list ALL involved Skills, not just the final one.
            4. If the "Recent known tool-result summary" already provides partial info, plan the remaining Skills accordingly; do not skip them.
            5. If the user's needs require no Skill at all, return `[]`.
            6. If completely unable to decide, return an empty `required_skills` and set `needs_clarification` to one specific English clarification question (one plain English sentence, do not quote these rules).
            <turn|>
            <|turn>model

            """

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + userBlock
    }

    static func buildSkillPlanningPrompt(
        originalPrompt: String,
        userQuestion: String,
        availableSkillsSummary: String,
        recentContextSummary: String = "",
        currentImageCount: Int = 0
    ) -> String {
        let isZh = LanguageService.shared.current.isChinese
        let systemBlock = extractSystemBlock(from: originalPrompt)
        let extraInstructions: String = isZh
            ? """
            对于当前这一个用户问题，你现在只负责生成完整的执行计划。
            不要调用 `load_skill`，不要输出 `<tool_call>`，不要直接回答用户问题。

            本阶段只允许使用以下已选中的 Skill 与工具：
            \(availableSkillsSummary)
            """
            : """
            For this user question, your only job is to produce a full execution plan.
            Do not call `load_skill`, do not emit `<tool_call>`, do not answer the user directly.

            Only the following already-selected Skills and tools are allowed in this stage:
            \(availableSkillsSummary)
            """
        let systemInstructions = injectIntoSystemBlock(systemBlock, extraInstructions: extraInstructions)

        let recentContextBlock: String
        if recentContextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recentContextBlock = ""
        } else {
            recentContextBlock = isZh
                ? """

                最近已知的工具结果摘要（可作为当前规划的上下文）：
                \(recentContextSummary)
                """
                : """

                Recent known tool-result summary (as context for planning):
                \(recentContextSummary)
                """
        }

        let userBlock: String = isZh
            ? """
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
            8. 只有在完全没有任何可行步骤可以获得关键缺失信息时, 才把 steps 留空数组,
               同时把 needs_clarification 字段填成一句具体追问 (一句中文, 不要复读本规则的字面文本).
            <turn|>
            <|turn>model

            """
            : """
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))\(recentContextBlock)

            Output ONE JSON object, format must be:
            {
              "goal": "one-line goal",
              "steps": [
                {
                  "id": "s1",
                  "skill": "skill_id",
                  "tool": "tool-name",
                  "intent": "what this step does",
                  "depends_on": []
                }
              ],
              "needs_clarification": null
            }

            Strictly follow these rules:
            1. Output only the JSON object — no Markdown, no code blocks, no explanations, no extra text.
            2. `skill` must be one of the skill ids above; `tool` must be one of the allowed tools for that skill, using the full tool name.
            3. Up to 4 steps, in execution order. Plan at least one step per selected skill.
            4. `depends_on` may only reference ids of earlier steps. If a step needs results from an earlier one, declare the dependency.
            5. If no skills or tools are needed, return `steps: []`.
            6. If info needed later can come from earlier steps or is already in "Recent known tool-result summary", still plan those earlier steps; do not ask prematurely.
            7. As long as `steps` can contain at least one executable step, `needs_clarification` must be null.
            8. Only when absolutely no executable step can obtain the key missing info, leave `steps` as an empty array and set `needs_clarification` to one specific English clarification question (one plain English sentence, do not quote these rules).
            <turn|>
            <|turn>model

            """

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + userBlock
    }

    static func buildPlannedToolArgumentsPrompt(
        originalPrompt: String,
        userQuestion: String,
        stepIntent: String,
        toolName: String,
        toolParameters: String,
        completedStepSummary: String = "",
        includeTimeAnchor: Bool = false,
        currentImageCount: Int = 0
    ) -> String {
        let isZh = LanguageService.shared.current.isChinese
        let systemBlock = extractSystemBlock(from: originalPrompt, includeTimeAnchor: includeTimeAnchor)
        let extraInstructions: String = isZh
            ? """
            对于当前这一个用户问题，你现在只负责为工具提取参数。
            不要调用 `load_skill`，不要输出 `<tool_call>`，不要直接回答用户问题。
            """
            : """
            For this user question, your only job is to extract arguments for a tool.
            Do not call `load_skill`, do not emit `<tool_call>`, do not answer the user directly.
            """
        let systemInstructions = injectIntoSystemBlock(systemBlock, extraInstructions: extraInstructions)

        let completedBlock: String
        if completedStepSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completedBlock = ""
        } else {
            completedBlock = isZh
                ? "已完成步骤摘要：\n\(completedStepSummary)"
                : "Completed steps summary:\n\(completedStepSummary)"
        }

        let userBlock: String = isZh
            ? """
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
            7. 只有用户原话完全没说某个必填参数 (tool 描述里标"可选"的不算必填),
               才输出 _needs_clarification 字段+一句具体追问. 绝大多数情况直接给 arguments.
            <turn|>
            <|turn>model

            """
            : """
            <|turn>user
            User question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            Current step goal:
            \(stepIntent)

            \(completedBlock)

            Your only job is to extract arguments for tool `\(toolName)`.
            Parameter spec:
            \(toolParameters)

            Strictly follow these rules:
            1. Do not invoke tools; do not emit `<tool_call>`.
            2. Output ONE JSON object, the arguments themselves.
            3. Do not output Markdown, code blocks, explanations, field drafts, or extra text.
            4. Omit optional fields if not present.
            5. If a prior completed step already has info the current tool needs, reference those results to fill parameters.
            6. Time fields must be converted to ISO 8601, e.g. `2026-04-07T20:00:00`.
            7. Only if the user's literal words omitted a required parameter (fields marked "optional" in the tool spec are not required), output a `_needs_clarification` field with one specific follow-up. In most cases, give arguments directly.
            <turn|>
            <|turn>model

            """

        return systemInstructions + extractHistoryBlock(from: originalPrompt) + userBlock
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
        let isZh = LanguageService.shared.current.isChinese
        let systemBlock = extractSystemBlock(from: originalPrompt)

        // 关键: prior step 结果用三引号包裹明确隔离, 让 SKILL (例如 translate) 按
        // 自己规则准确识别"源文本". 之前 prior result 跟 user 原问题混在一起,
        // model 错把 user 原话当源文本翻译了 — 真机 E4B "读剪贴板, 翻译成英文"
        // 输出 "Read clipboard, translate to English." 复述用户原话, 没翻译剪贴板内容.
        let priorResultBlock: String
        if completedStepSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            priorResultBlock = ""
        } else {
            priorResultBlock = isZh
                ? """

                上游步骤的输出 (这是本步的输入数据):
                \"\"\"
                \(completedStepSummary)
                \"\"\"

                """
                : """

                Upstream step output (this is the input for this step):
                \"\"\"
                \(completedStepSummary)
                \"\"\"

                """
        }

        let userBlock: String = isZh
            ? """
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
            : """
            <|turn>user
            Step goal (Skill task): \(stepIntent)
            \(priorResultBlock)
            Handle the input data above per the Skill instructions below (no tool is callable this step — output the final text result directly):

            \(skillInstructions)

            Important:
            - The input data is what's inside the triple-quoted block above, NOT the user's original question.
            - Output the final text result directly; do not repeat the input, do not explain the process.
            - Do not emit `<tool_call>`; do not use Markdown code blocks.
            <turn|>
            <|turn>model

            """

        return systemBlock + extractHistoryBlock(from: originalPrompt) + userBlock
    }

    static func buildMultiToolAnswerPrompt(
        originalPrompt: String,
        toolResults: [(toolName: String, result: String)],
        userQuestion: String,
        currentImageCount: Int = 0
    ) -> String {
        let systemBlock = extractSystemBlock(from: originalPrompt)

        // 用户可见输出路径 — planner 多工具 final answer. 英文 locale 下整套
        // user block 必须英文, 否则 planner 链英文用户最终回复被拉回中文。
        // zh 分支逐行字节相同原文本 (保证 harness 中文路径不 regress)。
        if LanguageService.shared.current.isChinese {
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
        } else if LanguageService.shared.current.isJapanese {
            var resultsBlock = ""
            for (toolName, result) in toolResults {
                resultsBlock += "ツール \(toolName) の実行結果：\(result)\n"
            }

            return systemBlock + extractHistoryBlock(from: originalPrompt) + """
            <|turn>user
            ユーザーの元の質問：
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            すべてのツールの実行が完了しました：
            \(resultsBlock)

            以上のすべての結果に基づいてユーザーに答えてください：
            - 以上の結果でユーザーの質問に答えられるなら、最終回答を直接出し、すでに成功したツールを再度呼び出さないでください。
            - 答えを補うために新しいツールをさらに呼び出す必要がある場合は、1つ以上の `<tool_call>...</tool_call>` を出力してかまいません。
            - 聞き返さず、ツール名・Skill・status・result・arguments などのフィールドに言及しないでください。
            - Markdown のコードブロックも、JSON・キー名・テンプレート・中間ステップも出力しないでください。
            - 空白を出力しないでください。
            <turn|>
            <|turn>model

            """
        } else {
            var resultsBlock = ""
            for (toolName, result) in toolResults {
                resultsBlock += "Result of tool \(toolName): \(result)\n"
            }

            return systemBlock + extractHistoryBlock(from: originalPrompt) + """
            <|turn>user
            Original user question:
            \(userQuestion)\(imagePromptSuffix(count: currentImageCount))

            All tools have finished executing:
            \(resultsBlock)

            Answer the user based on all results above:
            - If the results already answer the user's question, give the final answer directly; do not re-invoke tools that already succeeded.
            - If you still need to call new tools to complete the answer, emit one or more `<tool_call>...</tool_call>`.
            - Do not ask clarifying questions, do not mention tool names, Skill, status, result, arguments, or any other internal field.
            - Do not output Markdown code blocks, JSON, key names, templates, or intermediate steps.
            - Do not output empty content.
            <turn|>
            <|turn>model

            """
        }
    }

    // MARK: - KV Cache Delta Prompt Builders
    //
    // 用于 persistent session 模式：只传增量 delta，KV cache 复用之前的 context。
    // lastModelOutput 是上一轮 model 生成的完整文本。

    /// 构造增量 delta prompt (纯文本对话 follow-up)
    /// KV cache 已包含 model 输出 (生成的 token 逐个进入 cache)，
    /// delta 只需: 关闭上轮 model turn + 新 user turn + 打开新 model turn。
    static func buildDeltaTurnPrompt(
        userMessage: String,
        currentImageCount: Int = 0,
        enableThinking: Bool = false
    ) -> String {
        var delta = "<turn|>\n"
        delta += "<|turn>user\n\(userMessage)\(imagePromptSuffix(count: currentImageCount))<turn|>\n"
        delta += "<|turn>model\n"
        if enableThinking {
            delta += "<|think|>"
        }
        return delta
    }
}
