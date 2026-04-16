import Foundation

// MARK: - Live 语音模式 prompt builder
//
// 为什么独立 extension 文件:
//   主 PromptBuilder.swift 放通用 prompt 构建 (light / full Agent / multimodal).
//   Live 语音有一套自己的拼接逻辑 (手写 <|turn> 模板 + marker 约束 + vision
//   条件 + skill 通道 + i18n persona override), 合进去会让 PromptBuilder.swift
//   职责过杂.
//
// 为什么不走 UserInput(chat:) 而手写 <|turn> 模板:
//   Harness (2026-04-16) 用 CLI `live-probe` 实测对比 chat path vs prompt path
//   在 Gemma 4 4bit (E2B/E4B) 上对同一 system + user 输入:
//     - chat path   → persona 丢失 (E2B "我是大型语言模型, 谷歌训练过"), marker 失效
//     - prompt path → persona 守住 (E2B "✓ 我是...手机龙虾"), marker 生效
//   MLXLMCommon 的 applyChatTemplate 在 Gemma 4 tokenizer 上会稀释 system role
//   (built-in chat template 规范化过程里 system 约束被当成"对话背景"而非"刚性指令").
//   手写 <|turn>system/user/model 绕开这一步, 和原 iOS Chat light 路径行为一致.
//   多模态 image 通过 UserInput(prompt:images:) 挂载, 不强制走 chat API.
//
// i18n:
//   接受 `locale: LiveLocale` 参数, 不同语言场景下 persona / 约束模板自动切换.
//   SYSPROMPT.md 里其它语言的 persona 名 (如 "PhoneClaw") 会被替换成当前 locale
//   的 personaName, 消除 LLM 看到多个名字的冲突 (E4B 实测在冲突时会保守回避).

extension PromptBuilder {

    /// 构造 Live 语音模式的完整 prompt.
    ///
    /// 输出结构:
    /// ```
    /// <|turn>system
    /// {SYSPROMPT.md 内容, 其中 PhoneClaw 等被替换成 locale.personaName}
    /// {locale.voiceConstraints}                ← marker + 口语 + persona "{name}"
    /// {locale.visionConstraint}?               ← hasVision 时追加
    /// {preloadedSkills + locale.skillInvocationInstruction}? ← 阶段 3
    /// {locale.skillSuppressionInstruction}?    ← MVP 阶段, 阻止自发 tool_call
    /// <turn|>
    /// <|turn>user|model           ← historyDepth 轮 user/assistant 交替
    /// ...
    /// <|turn>user
    /// {userTranscript}{locale.userHint}{imagePromptSuffix?}
    /// <turn|>
    /// <|turn>model
    /// ```
    static func buildLiveVoicePrompt(
        userSystemPrompt: String?,
        locale: LiveLocale = .zhCN,
        history: [(role: String, content: String)],
        historyDepth: Int = 4,
        userTranscript: String,
        hasVision: Bool,
        imageCount: Int = 0,
        preloadedSkills: [PreloadedSkill] = []
    ) -> String {
        let cfg = locale.config

        let systemBody = buildLiveSystemBody(
            userSystemPrompt: userSystemPrompt,
            hasVision: hasVision,
            preloadedSkills: preloadedSkills,
            cfg: cfg
        )
        var prompt = "<|turn>system\n\(systemBody)\n<turn|>\n"

        prompt += buildLiveHistoryBlock(history: history, historyDepth: historyDepth)

        // 注意: 不拼 imagePromptSuffix.
        //
        // generateStream(rawText:images:) 在有 image 时走 .chat 分支
        // (`UserInput(chat: [.user(text, images:...)])`), Gemma 4 的
        // chat template + Gemma3StructuredMessageGenerator 会自己往
        // user content 里插一个 <|image|> placeholder, 然后 [Int] 版
        // expandImageTokens 把它扩成 boi + 160×image + eoi.
        //
        // 如果我们这里再 imagePromptSuffix(count:) 一个 <|image|>,
        // 总 placeholder = 2, 扩成 320 个 image soft tokens, 但 vision
        // encoder 仍只输出 160 → maskedScatter 错位, MLX 分配巨大 buffer
        // 触发 EXC_RESOURCE 闪崩 (真机 2026-04-16 验证).
        let userBody = userTranscript + cfg.userHint
        prompt += "<|turn>user\n\(userBody)\n<turn|>\n"
        prompt += "<|turn>model\n"

        return prompt
    }

    // MARK: - Private composition helpers

    private static func buildLiveSystemBody(
        userSystemPrompt: String?,
        hasVision: Bool,
        preloadedSkills: [PreloadedSkill],
        cfg: LiveLocaleConfig
    ) -> String {
        var body = (userSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? userSystemPrompt!
                    : defaultSystemPrompt)

        // ── i18n persona override ──────────────────────────────────────────
        // SYSPROMPT.md 里的英文/其它 persona 名字替换成当前 locale 的 personaName.
        // 让 LLM 看到的 system prompt 里只有一个 persona, 不会因冲突 retreat.
        for alias in cfg.personaAliasesToReplace {
            body = body.replacingOccurrences(of: alias, with: cfg.personaName)
        }

        // ── Skill section 裁剪 (MVP 阶段) ─────────────────────────────────
        // 真机 2026-04-16 验证: 仅靠 skillSuppressionInstruction 尾缀压不住 —
        // SYSPROMPT.md 里 `<tool_call>{"name":"load_skill",...}</tool_call>` 字面
        // 给模型太具体的"照学"模板, suppression 写"不要" 反而比"具体格式" 弱.
        //
        // 真正修法: 按段落裁掉含 skill 关键词的段及其后, LLM 根本看不到 <tool_call>
        // 字面就不会模仿. 这是 light path "只取第一段" 思路的更宽松版本 ——
        // 不是只取第一段, 而是保留所有不含 skill 关键词的段直到第一个 skill 段.
        if preloadedSkills.isEmpty {
            body = trimSkillSections(from: body)
        }

        body += "\n\n" + cfg.voiceConstraints

        if hasVision {
            body += "\n" + cfg.visionConstraint
        }

        if !preloadedSkills.isEmpty {
            // 阶段 3: 启用 skill 调用通道, 拼 skill body + invocation instruction
            body += "\n\n━━ 可用 Skill (已预加载) ━━\n"
            for sk in preloadedSkills {
                body += "\n━━ Skill: \(sk.displayName) ━━\n"
                body += sk.body + "\n"
            }
            body += "━━━━━━━━━━━━━━━━━━━━\n\n"
            body += cfg.skillInvocationInstruction
        } else {
            // 阶段 1/2: skill 章节已裁掉, 这里再加一道 suppression 兜底.
            body += "\n\n" + cfg.skillSuppressionInstruction
        }

        return body
    }

    /// 按段 (`\n\n` 分隔) 裁掉 SYSPROMPT.md 里的 skill 描述部分.
    ///
    /// 策略: 从开头逐段保留, 一旦遇到含 skill 关键词的段就停. 这样:
    ///   - persona / 风格描述 (通常在前) 完整保留
    ///   - skill 章节 (含 `<tool_call>` 字面 / "调用格式" / "load_skill" 等) 全部去掉
    ///
    /// kDefaultSystemPrompt 案例:
    ///   ```
    ///   你是 PhoneClaw, 一个本地 AI 助手...保护用户隐私.   ← 保留 (persona 段)
    ///                                                       ← 切点 (下一段含 "Skill")
    ///   你拥有以下两类能力（Skill）：                       ← 砍掉
    ///   【设备操作类】...                                    ← 砍掉
    ///   调用格式: <tool_call>{...}</tool_call>...           ← 砍掉
    ///   ```
    private static func trimSkillSections(from body: String) -> String {
        let skillKeywords: [String] = [
            "<tool_call>", "load_skill", "tool_call",
            "调用格式", "调用规则",
            "Skill", "skill", "技能",
        ]
        let segments = body.components(separatedBy: "\n\n")
        var kept: [String] = []
        for seg in segments {
            if skillKeywords.contains(where: { seg.contains($0) }) {
                break
            }
            kept.append(seg)
        }
        // 全段都被砍 (极端情况, 用户 SYSPROMPT.md 第一段就含 skill 关键词)
        // 兜底返回 defaultSystemPrompt, 至少有 persona.
        if kept.isEmpty {
            return defaultSystemPrompt
        }
        return kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildLiveHistoryBlock(
        history: [(role: String, content: String)],
        historyDepth: Int
    ) -> String {
        var block = ""
        let recent = history.suffix(historyDepth)
        for msg in recent {
            let role = msg.role == "assistant" ? "model" : "user"
            // Assistant 历史里可能残留 marker 字符, 清掉再入历史上下文,
            // 避免模型误以为 marker 是普通回答的一部分.
            let cleaned = msg.role == "assistant"
                ? sanitizedAssistantHistoryContent(msg.content)
                : msg.content
            if cleaned.isEmpty { continue }
            block += "<|turn>\(role)\n\(cleaned)\n<turn|>\n"
        }
        return block
    }
}
