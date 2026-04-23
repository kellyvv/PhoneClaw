import CoreImage
import Foundation

// MARK: - Planner 内部数据类型（仅 Planner 使用，文件级私有）

struct ExecutionPlanStep {
    let id: String
    let skill: String
    let tool: String
    let intent: String
    let dependsOn: [String]
}

struct ExecutionPlan {
    let goal: String
    let steps: [ExecutionPlanStep]
    let needsClarification: String?
}

struct SkillSelection {
    let goal: String
    let requiredSkills: [String]
    let needsClarification: String?
}

struct ExecutedPlanStep {
    let step: ExecutionPlanStep
    let toolResult: String
    let toolResultSummary: String
}

extension AgentEngine {

    // MARK: - Skill 描述构造

    func buildAvailableSkillsSummary(
        skillIds: [String],
        compact: Bool = false
    ) -> String {
        let selectedIds = uniqueStringsPreservingOrder(skillIds)
        let chosenEntries: [SkillEntry]
        if selectedIds.isEmpty {
            chosenEntries = skillEntries.filter(\.isEnabled)
        } else {
            let selectedSet = Set(selectedIds)
            chosenEntries = skillEntries.filter { $0.isEnabled && selectedSet.contains($0.id) }
        }

        return chosenEntries.map { entry in
            if compact {
                let tools = registeredTools(for: entry.id).map(\.name).joined(separator: "、")
                return "- \(entry.id): \(tools)"
            } else {
                let tools = registeredTools(for: entry.id).map {
                    "\($0.name): \($0.description)"
                }.joined(separator: "；")
                return """
                - \(entry.id)(\(entry.name)): \(entry.description)
                  可用工具: \(tools)
                """
            }
        }.joined(separator: "\n")
    }

    func recentPlannerContextSummary(limit: Int = 2) -> String {
        let toolNames = Set(
            skillEntries
                .filter(\.isEnabled)
                .flatMap { registeredTools(for: $0.id).map(\.name) }
        )
        guard !toolNames.isEmpty else { return "" }

        var blocks: [String] = []
        for message in messages.reversed() {
            guard message.role == .skillResult,
                  let skillName = message.skillName,
                  toolNames.contains(skillName) else {
                continue
            }

            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let summary: String
            if trimmed.count > 220 {
                summary = String(trimmed.prefix(220)) + "..."
            } else {
                summary = trimmed
            }

            blocks.append("- \(skillName): \(summary)")
            if blocks.count >= limit {
                break
            }
        }

        return blocks.reversed().joined(separator: "\n")
    }

    // MARK: - 计划解析

    func parseExecutionPlan(_ text: String) -> ExecutionPlan? {
        guard let object = parseJSONObject(text) else { return nil }
        let goal = object["goal"] as? String ?? ""
        let needsClarification = object["needs_clarification"] as? String
        let rawSteps = object["steps"] as? [[String: Any]] ?? []

        let steps = rawSteps.compactMap { rawStep -> ExecutionPlanStep? in
            guard let id = rawStep["id"] as? String,
                  let skill = rawStep["skill"] as? String,
                  let tool = rawStep["tool"] as? String,
                  let intent = rawStep["intent"] as? String else {
                return nil
            }
            let dependsOn = rawStep["depends_on"] as? [String] ?? []
            return ExecutionPlanStep(
                id: id,
                skill: skill,
                tool: tool,
                intent: intent,
                dependsOn: dependsOn
            )
        }

        return ExecutionPlan(goal: goal, steps: steps, needsClarification: needsClarification)
    }

    func parseSkillSelection(_ text: String) -> SkillSelection? {
        guard let object = parseJSONObject(text) else { return nil }
        let goal = object["goal"] as? String ?? ""
        let requiredSkills = object["required_skills"] as? [String] ?? []
        let needsClarification = object["needs_clarification"] as? String
        return SkillSelection(
            goal: goal,
            requiredSkills: requiredSkills,
            needsClarification: needsClarification
        )
    }

    func validateSkillSelection(
        _ selection: SkillSelection,
        candidateSkillIds: [String]
    ) -> SkillSelection? {
        let clarification = selection.needsClarification?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // T2g (2026-04-17): 之前的逻辑是 clarification 非空就直接返 (skills=[]).
        // 现在保留两边: 让 caller 决定 clarification 该不该当真. SLM 经常把 args
        // 缺失写进 needs_clarification —— 如果同时给了 skills, 多半是误报.
        let normalizedSkills = uniqueStringsPreservingOrder(
            selection.requiredSkills.compactMap { canonicalSkillSelectionEntry($0) }
        )

        let enabledSkillSet = Set(skillEntries.filter(\.isEnabled).map(\.id))
        let candidateSet = candidateSkillIds.isEmpty ? enabledSkillSet : Set(candidateSkillIds)
        let validSkills = normalizedSkills.filter {
            enabledSkillSet.contains($0) && (candidateSet.contains($0) || candidateSkillIds.isEmpty)
        }

        // 若两个都为空 → 当无效 (LLM 没真返回任何信号)
        if validSkills.isEmpty && (clarification ?? "").isEmpty {
            return nil
        }

        // skills 数量上限 3, 超过截断而非整体失败
        let cappedSkills = Array(validSkills.prefix(3))

        return SkillSelection(
            goal: selection.goal,
            requiredSkills: cappedSkills,
            needsClarification: clarification
        )
    }

    func validateExecutionPlan(
        _ plan: ExecutionPlan,
        candidateSkillIds: [String]
    ) -> ExecutionPlan? {
        let clarification = plan.needsClarification?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let clarification, !clarification.isEmpty, plan.steps.isEmpty {
            return ExecutionPlan(goal: plan.goal, steps: [], needsClarification: clarification)
        }

        guard !plan.steps.isEmpty, plan.steps.count <= 4 else {
            return nil
        }

        let enabledSkillSet = Set(skillEntries.filter(\.isEnabled).map(\.id))
        let candidateSet = candidateSkillIds.isEmpty ? enabledSkillSet : Set(candidateSkillIds)
        var seenStepIds: Set<String> = []
        var previousStepIds: Set<String> = []

        let uniqueSkillCount = Set(plan.steps.map(\.skill)).count
        guard uniqueSkillCount <= 3 else { return nil }

        for step in plan.steps {
            let stepID = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let skillID = skillRegistry.canonicalSkillId(for: step.skill)
            let toolName = canonicalToolName(
                step.tool,
                arguments: [:],
                preferredSkillId: step.skill
            )

            guard !stepID.isEmpty,
                  !step.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seenStepIds.contains(stepID),
                  enabledSkillSet.contains(skillID),
                  candidateSet.contains(skillID) || candidateSkillIds.isEmpty else {
                return nil
            }

            // C1 (2026-04-17): content-type SKILL (例如 translate) `allowed-tools: []`,
            // 没有 tool 可调 — 模型按 SKILL.md 指令直接生成结果. Planner step 的
            // `tool` 字段 ignore. device-type SKILL 仍须有合法 tool.
            let allowedToolNames = Set(registeredTools(for: skillID).map(\.name))
            let isContentSkill = allowedToolNames.isEmpty
            if !isContentSkill {
                guard allowedToolNames.contains(toolName) else { return nil }
            }

            guard step.dependsOn.allSatisfy({ previousStepIds.contains($0) }) else {
                return nil
            }

            seenStepIds.insert(stepID)
            previousStepIds.insert(stepID)
        }

        let normalizedSteps = plan.steps.map { step in
            ExecutionPlanStep(
                id: step.id,
                skill: skillRegistry.canonicalSkillId(for: step.skill),
                tool: canonicalToolName(
                    step.tool,
                    arguments: [:],
                    preferredSkillId: step.skill
                ),
                intent: step.intent,
                dependsOn: step.dependsOn
            )
        }

        return ExecutionPlan(goal: plan.goal, steps: normalizedSteps, needsClarification: nil)
    }

    func completedPlanSummary(_ completedSteps: [ExecutedPlanStep]) -> String {
        completedSteps.map { completedStep in
            let summary = completedStep.toolResultSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            let compactSummary: String
            if summary.count > 160 {
                compactSummary = String(summary.prefix(160)) + "..."
            } else {
                compactSummary = summary
            }

            let block = """
            [\(completedStep.step.id)] \(completedStep.step.tool)
            目标:\(completedStep.step.intent)
            可直接给用户的结果:\(compactSummary)
            """

            return block
        }.joined(separator: "\n\n")
    }

    // MARK: - 多 Skill 编排主入口

    @discardableResult
    func executePlannedSkillChainIfPossible(
        prompt: String,
        userQuestion: String,
        images: [CIImage]
    ) async -> Bool {
        let matchedSkills = matchedSkillIds(for: userQuestion)
        log("[Agent] \(plannerRevision) matchedSkills=\(matchedSkills.joined(separator: ","))")
        let recentContextSummary = recentPlannerContextSummary()
        // T2c (2026-04-17): 移除"matched>=2 跳过 Selection"的本地短路.
        // Router 可能命中 2 个 SKILL 但漏第 3 个 (#02 fail), 必须让 Selection LLM
        // 拿全 enabled skill set 决策. matched 仅作 candidates 优先 hint.
        // 代价: 多一次短 LLM call (~1s on E4B). 收益: 矫正 Router 漏匹配.
        // Selection LLM 总跑, 用全 enabled skill set 作为可选范围.
        let selectionCandidateSkillIds = skillEntries.filter(\.isEnabled).map(\.id)
        let selectionSkillsSummary = buildAvailableSkillsSummary(skillIds: selectionCandidateSkillIds)
        let selectedSkillIds: [String]
        guard !selectionSkillsSummary.isEmpty else {
            messages.append(ChatMessage(role: .assistant, content: "⚠️ 当前没有可用于编排的 Skill。"))
            isProcessing = false
            return true
        }

        let selectionPrompt = PromptBuilder.buildSkillSelectionPrompt(
            originalPrompt: prompt,
            userQuestion: userQuestion,
            availableSkillsSummary: selectionSkillsSummary,
            recentContextSummary: recentContextSummary,
            currentImageCount: images.count
        )
        log("[Agent] skill selection prompt chars=\(selectionPrompt.count), candidateSkills=\(selectionCandidateSkillIds.count)")

        // T2d (2026-04-17): Selection LLM 失效场景下用 Router matched 作为兜底.
        //
        // E2B 在 Selection prompt (6 SKILL × 中文) 下经常翻车 — 截断 JSON, 复读 prompt 里的
        // 字面 clarification 示例 ("请说明具体需要什么帮助"), 输出 0 token 等. 这些是
        // SLM 推理边界, 不是模型 bug. 解法: 失败时若 matched>=2 静默回 matched, 让 planning
        // 仍能跑下去, 避免给用户错误消息. 这不是硬编规则, 是 graceful degradation.
        //
        // 失败模式分类:
        //   A. streamLLM 返回 nil → 用 matched
        //   B. parse/validate 失败 → 用 matched
        //   C. validated 给的 clarification == prompt 字面示例 → 用 matched
        //   D. validated.required.count < 2 (真单 skill) → 返回 false (落回单 skill agent)
        //   E. validated.required.count >= 2 → 用 LLM 选的
        let placeholderClarification = "请说明具体需要什么帮助"

        let rawSelection = await streamLLM(prompt: selectionPrompt, images: images)
        let cleanedSelection = rawSelection.map { cleanOutput($0) } ?? ""

        let parsedSelection = parseSkillSelection(cleanedSelection)
        let validatedSelection = parsedSelection.flatMap {
            validateSkillSelection($0, candidateSkillIds: selectionCandidateSkillIds)
        }

        // C: clarification 是 prompt 字面示例, 视为 LLM 没真理解
        let clarificationLooksFake: Bool = {
            guard let clar = validatedSelection?.needsClarification?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clar.isEmpty else { return false }
            return clar == placeholderClarification
        }()

        // 真 clarification (非 prompt 字面) → 让用户看到.
        // 但只有当 required_skills 为空时才认为是真 clarification —— 如果 LLM 同时
        // 给了 skills 又给了 clarification, clarification 多半是它把"args 缺失"
        // 误当成"selection 缺信息"了 (Selection 阶段不该问 args). 直接忽略 clar,
        // 用 skills 进入 plan.
        let hasSkills = (validatedSelection?.requiredSkills.isEmpty == false)
        if let clar = validatedSelection?.needsClarification,
           !clar.isEmpty,
           !clarificationLooksFake,
           !hasSkills {
            messages.append(ChatMessage(role: .assistant, content: clar))
            isProcessing = false
            return true
        }

        // D: 真单 skill → 落回 agent 单 skill 路径
        if let req = validatedSelection?.requiredSkills, req.count == 1 {
            log("[Agent] selection returned single skill, fall back to agent path")
            return false
        }

        // E: 多 skill → 用 Selection 结果
        if let req = validatedSelection?.requiredSkills, req.count >= 2 {
            selectedSkillIds = req
            log("[Agent] skill selection accepted skills=\(selectedSkillIds.joined(separator: ","))")
        } else if matchedSkills.count >= 2 {
            // A/B/C: Selection 失效, Router 匹配到 >=2 → 兜底
            selectedSkillIds = matchedSkills
            log("[Agent] selection failed/empty, falling back to Router matched skills=\(selectedSkillIds.joined(separator: ","))")
        } else {
            // Selection 失效 + Router 也只有 0/1 → 落回 agent 单 skill 路径 (matched=1)
            // 或写错误消息 (matched=0, 不可能进 planner 因为 gate>=1)
            log("[Agent] selection failed and Router matched<2, fall back to agent path")
            return false
        }

        var loadedInstructions: [String: String] = [:]
        var loadedDisplayNames: [String: String] = [:]
        var skillCardIndices: [String: Int] = [:]
        var completedSteps: [ExecutedPlanStep] = []
        var toolResultsForAnswer: [(toolName: String, result: String)] = []
        var remainingSkillIds = selectedSkillIds
        var planningPass = 0

        func finishPlanning(with message: String? = nil) {
            if let message, !message.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: message))
            }
            markSkillsDone(Array(loadedDisplayNames.values))
            isProcessing = false
        }

        while !remainingSkillIds.isEmpty, planningPass < 3 {
            planningPass += 1

            let combinedContextSummary = [recentContextSummary, completedPlanSummary(completedSteps)]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            let availableSkillsSummary = buildAvailableSkillsSummary(
                skillIds: remainingSkillIds,
                compact: true
            )
            guard !availableSkillsSummary.isEmpty else { break }

            let planningPrompt = PromptBuilder.buildSkillPlanningPrompt(
                originalPrompt: prompt,
                userQuestion: userQuestion,
                availableSkillsSummary: availableSkillsSummary,
                recentContextSummary: combinedContextSummary,
                currentImageCount: images.count
            )
            log("[Agent] planner prompt chars=\(planningPrompt.count), candidateSkills=\(remainingSkillIds.count), pass=\(planningPass)")

            guard let rawPlan = await streamLLM(prompt: planningPrompt, images: images) else {
                let message = completedSteps.isEmpty
                    ? "⚠️ 无法生成执行计划，请重试。"
                    : "⚠️ 无法继续规划剩余步骤，请重试。"
                finishPlanning(with: message)
                return true
            }

            let cleanedPlan = cleanOutput(rawPlan)
            guard let parsedPlan = parseExecutionPlan(cleanedPlan),
                  let validatedPlan = validateExecutionPlan(parsedPlan, candidateSkillIds: remainingSkillIds) else {
                let message = completedSteps.isEmpty
                    ? "⚠️ 当前无法生成有效计划，请把需求说得更具体一些。"
                    : "⚠️ 当前无法继续规划剩余步骤，请把需求说得更具体一些。"
                finishPlanning(with: message)
                return true
            }

            if let clarification = validatedPlan.needsClarification,
               !clarification.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: clarification))
                isProcessing = false
                return true
            }

            guard !validatedPlan.steps.isEmpty else {
                let message = completedSteps.isEmpty
                    ? "⚠️ 当前没有可执行步骤，请补充更具体的信息。"
                    : "⚠️ 当前无法继续规划剩余步骤，请补充更具体的信息。"
                finishPlanning(with: message)
                return true
            }

            log("[Agent] planner accepted plan with \(validatedPlan.steps.count) steps")

            let executedSkillIdsThisPass = uniqueStringsPreservingOrder(validatedPlan.steps.map(\.skill))

            for step in validatedPlan.steps {
                if loadedInstructions[step.skill] == nil {
                    let displayName = findDisplayName(for: step.skill)
                    loadedDisplayNames[step.skill] = displayName
                    messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
                    let cardIndex = messages.count - 1
                    skillCardIndices[step.skill] = cardIndex

                    guard let instructions = handleLoadSkill(skillName: step.skill) else {
                        messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
                        finishPlanning(with: "⚠️ 无法加载 Skill \(displayName)，已停止执行。")
                        return true
                    }

                    try? await Task.sleep(for: .milliseconds(300))
                    messages[cardIndex].update(role: .system, content: "loaded", skillName: displayName)
                    messages.append(ChatMessage(role: .skillResult, content: instructions, skillName: step.skill))
                    loadedInstructions[step.skill] = instructions
                }

                let displayName = loadedDisplayNames[step.skill] ?? findDisplayName(for: step.skill)
                guard let cardIndex = skillCardIndices[step.skill] else {
                    finishPlanning(with: "⚠️ 当前规划步骤无效，已停止执行。")
                    return true
                }

                // C1 (2026-04-17): content-type SKILL 没有 tool — 模型按 SKILL.md 指令直接
                // 生成文本结果. 这一步绕开 tool 提取/调用, 走 buildContentStepPrompt 直接 LLM.
                let skillDef = skillRegistry.getDefinition(step.skill)
                let isContentStep = skillDef?.metadata.allowedTools.isEmpty == true
                if isContentStep {
                    let completedSummary = completedPlanSummary(completedSteps)
                    let contentPrompt = PromptBuilder.buildContentStepPrompt(
                        originalPrompt: prompt,
                        userQuestion: userQuestion,
                        skillInstructions: loadedInstructions[step.skill] ?? "",
                        stepIntent: step.intent,
                        completedStepSummary: completedSummary,
                        currentImageCount: images.count
                    )

                    messages[cardIndex].update(role: .system, content: "executing:\(step.skill)", skillName: displayName)

                    guard let rawOutput = await streamLLM(prompt: contentPrompt, images: images) else {
                        messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
                        finishPlanning(with: "⚠️ \(displayName) 步骤无回复，请重试。")
                        return true
                    }

                    let cleanedOutput = cleanOutput(rawOutput)
                    let summary = cleanedOutput.isEmpty ? "(无输出)" : cleanedOutput

                    messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
                    messages.append(ChatMessage(role: .skillResult, content: summary, skillName: step.skill))

                    completedSteps.append(
                        ExecutedPlanStep(
                            step: step,
                            toolResult: summary,
                            toolResultSummary: summary
                        )
                    )
                    toolResultsForAnswer.append((toolName: step.skill, result: summary))
                    continue
                }

                guard let tool = toolRegistry.find(name: step.tool) else {
                    finishPlanning(with: "⚠️ 当前规划步骤无效，已停止执行。")
                    return true
                }

                let arguments: [String: Any]
                if tool.isParameterless {
                    arguments = [:]
                } else {
                    let completedSummary = completedPlanSummary(completedSteps)
                    let argumentsPrompt = PromptBuilder.buildPlannedToolArgumentsPrompt(
                        originalPrompt: prompt,
                        userQuestion: userQuestion,
                        stepIntent: step.intent,
                        toolName: step.tool,
                        toolParameters: tool.parameters,
                        completedStepSummary: completedSummary,
                        includeTimeAnchor: requiresTimeAnchor(forSkillId: step.skill),
                        currentImageCount: images.count
                    )

                    guard let rawArguments = await streamLLM(prompt: argumentsPrompt, images: images) else {
                        finishPlanning(with: "⚠️ 无法提取步骤参数，请重试。")
                        return true
                    }

                    let cleanedArguments = cleanOutput(rawArguments)
                    guard let payload = parseJSONObject(cleanedArguments) else {
                        finishPlanning(with: "⚠️ 无法提取步骤参数，请把需求说得更具体一些。")
                        return true
                    }

                    if let clarification = payload["_needs_clarification"] as? String,
                       !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finishPlanning(with: clarification)
                        return true
                    }

                    guard toolRegistry.validatesArguments(payload, for: step.tool) else {
                        finishPlanning(with: "⚠️ 当前步骤缺少必要参数，请把需求说得更具体一些。")
                        return true
                    }

                    arguments = payload
                }

                messages[cardIndex].update(
                    role: .system,
                    content: "executing:\(step.tool)",
                    skillName: displayName
                )

                do {
                    let canonicalResult: CanonicalToolResult
                    let toolResultDetail: String
                    if HotfixFeatureFlags.useHotfixPromptPipeline && HotfixFeatureFlags.enableCanonicalToolResult {
                        canonicalResult = try await handleToolExecutionCanonical(
                            toolName: step.tool,
                            args: arguments
                        )
                        toolResultDetail = canonicalResult.detail
                    } else {
                        let toolResult = try await handleToolExecution(toolName: step.tool, args: arguments)
                        canonicalResult = canonicalToolResult(toolName: step.tool, toolResult: toolResult)
                        toolResultDetail = toolResult
                    }

                    messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
                    messages.append(ChatMessage(role: .skillResult, content: toolResultDetail, skillName: step.tool))

                    if !canonicalResult.success {
                        finishPlanning(with: canonicalResult.summary)
                        return true
                    }

                    completedSteps.append(
                        ExecutedPlanStep(
                            step: step,
                            toolResult: toolResultDetail,
                            toolResultSummary: canonicalResult.summary
                        )
                    )
                    toolResultsForAnswer.append((toolName: step.tool, result: canonicalResult.summary))
                } catch {
                    messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
                    finishPlanning(with: "❌ Tool 执行失败:\(error.localizedDescription)")
                    return true
                }
            }

            remainingSkillIds.removeAll { executedSkillIdsThisPass.contains($0) }
        }

        if !remainingSkillIds.isEmpty {
            finishPlanning(with: "⚠️ 还缺少部分步骤未完成，请把需求说得更具体一些。")
            return true
        }

        let followUpPrompt = PromptBuilder.buildMultiToolAnswerPrompt(
            originalPrompt: prompt,
            toolResults: toolResultsForAnswer,
            userQuestion: userQuestion,
            currentImageCount: images.count
        )

        messages.append(ChatMessage(role: .assistant, content: "▍"))
        let followUpIndex = messages.count - 1

        guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
            markSkillsDone(Array(loadedDisplayNames.values))
            isProcessing = false
            return true
        }

        if !parseAllToolCalls(nextText).isEmpty {
            log("[Agent] planner follow-up detected extra tool call")
            messages[followUpIndex].update(content: "")
            await executeToolChain(
                prompt: followUpPrompt,
                fullText: nextText,
                userQuestion: userQuestion,
                images: images
            )
            return true
        }

        let cleaned = cleanOutput(nextText)
        let finalReply: String
        if cleaned.isEmpty
            || looksLikeStructuredIntermediateOutput(cleaned)
            || looksLikePromptEcho(cleaned) {
            finalReply = toolResultsForAnswer.map(\.result).joined(separator: "\n")
        } else {
            finalReply = cleaned
        }

        messages[followUpIndex].update(content: finalReply)
        markSkillsDone(Array(loadedDisplayNames.values))
        isProcessing = false
        return true
    }
}
