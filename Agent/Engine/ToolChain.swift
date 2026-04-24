import CoreImage
import Foundation

// MARK: - ToolChain 内部数据类型

enum SingleToolExtractionOutcome {
    case toolCall(name: String, arguments: [String: Any])
    case needsClarification(String)
    case failed
}

protocol ToolResultCanonicalizer {
    func canonicalize(toolName: String, toolResult: String) -> CanonicalToolResult
}

struct LegacyToolCanonicalizer: ToolResultCanonicalizer {
    func canonicalize(toolName: String, toolResult: String) -> CanonicalToolResult {
        canonicalToolResult(toolName: toolName, toolResult: toolResult)
    }
}

extension AgentEngine {

    // MARK: - Tool 注册查询

    func registeredTools(for skillId: String) -> [RegisteredTool] {
        if let def = skillRegistry.getDefinition(skillId) {
            let tools = toolRegistry.toolsFor(names: def.metadata.allowedTools)
            if !tools.isEmpty { return tools }
        }

        if let entry = skillEntries.first(where: { $0.id == skillId }) {
            let tools = entry.tools.compactMap { toolRegistry.find(name: $0.name) }
            if !tools.isEmpty { return tools }
        }

        return []
    }

    // MARK: - 单 Skill 自动 / 引导式工具调用

    func autoToolCallForLoadedSkills(
        skillIds: [String]
    ) -> (name: String, arguments: [String: Any])? {
        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds

        guard uniqueSkillIds.count == 1,
              let skillId = uniqueSkillIds.first,
              let def = skillRegistry.getDefinition(skillId),
              def.isEnabled else {
            return nil
        }

        let uniqueToolNames = Array(NSOrderedSet(array: def.metadata.allowedTools)) as? [String]
            ?? def.metadata.allowedTools
        guard uniqueToolNames.count == 1,
              let toolName = uniqueToolNames.first,
              let tool = toolRegistry.find(name: toolName),
              tool.isParameterless else {
            return nil
        }

        return (tool.name, [:])
    }

    func singleRegisteredToolForLoadedSkills(skillIds: [String]) -> RegisteredTool? {
        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds
        guard uniqueSkillIds.count == 1,
              let skillId = uniqueSkillIds.first else {
            return nil
        }

        let tools = registeredTools(for: skillId)
        guard tools.count == 1 else { return nil }
        return tools.first
    }

    func extractToolCallForLoadedSkills(
        originalPrompt: String,
        userQuestion: String,
        skillInstructions: String,
        skillIds: [String],
        images: [CIImage]
    ) async -> SingleToolExtractionOutcome {
        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds
        guard uniqueSkillIds.count == 1,
              let skillId = uniqueSkillIds.first else {
            return .failed
        }

        let tools = registeredTools(for: skillId)
            .filter { !$0.isParameterless }
        guard !tools.isEmpty else {
            return .failed
        }

        if tools.count == 1, let tool = tools.first {
            let extractionPrompt = PromptBuilder.buildSingleToolArgumentsPrompt(
                originalPrompt: originalPrompt,
                userQuestion: userQuestion,
                skillInstructions: skillInstructions,
                toolName: tool.name,
                toolParameters: tool.parameters,
                includeTimeAnchor: requiresTimeAnchor(forSkillId: skillId),
                currentImageCount: images.count
            )

            if let raw = await streamLLM(prompt: extractionPrompt, images: images) {
                let cleaned = cleanOutput(raw)
                if let payload = parseJSONObject(cleaned) {
                    if let clarification = payload["_needs_clarification"] as? String,
                       !clarification.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                        return .needsClarification(clarification)
                    }

                    if toolRegistry.validatesArguments(payload, for: tool.name) {
                        return .toolCall(name: tool.name, arguments: payload)
                    }
                }
            }

            return .failed
        }

        let allowedToolsSummary = tools.map {
            "- \($0.name): \($0.description)\n  参数: \($0.parameters)"
        }.joined(separator: "\n")

        let extractionPrompt = PromptBuilder.buildSkillToolSelectionPrompt(
            originalPrompt: originalPrompt,
            userQuestion: userQuestion,
            skillInstructions: skillInstructions,
            allowedToolsSummary: allowedToolsSummary,
            includeTimeAnchor: requiresTimeAnchor(forSkillId: skillId),
            currentImageCount: images.count
        )

        if let raw = await streamLLM(prompt: extractionPrompt, images: images) {
            let cleaned = cleanOutput(raw)
            if let payload = parseJSONObject(cleaned) {
                if let clarification = payload["_needs_clarification"] as? String,
                   !clarification.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                    return .needsClarification(clarification)
                }

                if let rawName = payload["name"] as? String,
                   let arguments = payload["arguments"] as? [String: Any] {
                    let toolName = canonicalToolName(rawName, arguments: arguments)
                    if tools.contains(where: { $0.name == toolName }),
                       toolRegistry.validatesArguments(arguments, for: toolName) {
                        return .toolCall(name: toolName, arguments: arguments)
                    }
                }
            }
        }

        return .failed
    }

    // MARK: - synthetic / payload helpers

    func syntheticToolCallText(
        name: String,
        arguments: [String: Any]
    ) -> String {
        let jsonData = try? JSONSerialization.data(withJSONObject: [
            "name": name,
            "arguments": arguments
        ])
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"name\":\"\(name)\",\"arguments\":{}}"
        return """
        <tool_call>
        \(jsonString)
        </tool_call>
        """
    }

    func parsedToolPayload(from toolResult: String) -> [String: Any]? {
        guard let data = toolResult.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    func toolResultSummaryForModel(
        toolName: String,
        toolResult: String
    ) -> String {
        toolResultCanonicalizer
            .canonicalize(toolName: toolName, toolResult: toolResult)
            .summary
    }

    func fallbackReplyForEmptyToolFollowUp(
        toolName: String,
        toolResultSummary: String,
        toolResultDetail: String
    ) -> String {
        let trimmed = toolResultDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = toolResultSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty, summary != trimmed {
            return summary
        }

        if trimmed.isEmpty {
            return tr(
                "工具 \(toolName) 已执行，但没有返回内容。",
                "Tool \(toolName) executed but returned no content."
            )
        }

        if LanguageService.shared.current.isChinese {
            return """
            工具 \(toolName) 已执行完成，但模型没有生成最终回答。
            工具返回结果：
            \(trimmed)
            """
        } else {
            return """
            Tool \(toolName) finished executing, but the model did not produce a final answer.
            Tool result:
            \(trimmed)
            """
        }
    }

    func fallbackReplyForEmptySkillFollowUp(skillName: String) -> String {
        tr(
            "Skill \(skillName) 已加载，但模型没有继续生成工具调用或最终回答。请重试，或把问题说得更具体一些。",
            "Skill \(skillName) is loaded, but the model did not continue with a tool call or final answer. Please retry, or rephrase the question more specifically."
        )
    }

    func markSkillsDone(_ displayNames: [String]) {
        guard !displayNames.isEmpty else { return }
        for index in messages.indices {
            guard messages[index].role == .system,
                  let skillName = messages[index].skillName,
                  displayNames.contains(skillName),
                  messages[index].content == "identified" || messages[index].content == "loaded" else {
                continue
            }
            messages[index].update(role: .system, content: "done", skillName: skillName)
        }
    }

    // MARK: - Tool 调用主循环

    func executeToolChain(
        prompt: String,
        fullText: String,
        userQuestion: String,
        images: [CIImage],
        round: Int = 1,
        maxRounds: Int = 10
    ) async {
        // P1-D (2026-04-17): 内存紧 + 进入 tool_call 链 → 限轮数 + skip duplicates.
        // 真机 E4B 真机 multi-SKILL: 模型可能跟自己第二次调同 tool (不进步) — 单
        // 短路会把后续合法的 reminders/contacts 步骤一起砍掉. 设计:
        //   1. 同名 tool 在最近 6 条 skillResult 已成功跑过 ≥1 次 → SKIP 本次
        //      执行 (不再调真 tool, 不消耗副作用 quota), 但塞一个 fake "已完成"
        //      tool_result 给模型, 让它继续推进下一个 tool 或给最终答案.
        //   2. maxRounds 内存紧时上限 6 (从原 3 抬上去) — 多 SKILL 串联场景:
        //      load_skill + tool + load_skill + tool + tool + 最终答案 大概 5-6 round.
        let effectiveMax = (MemoryStats.headroomMB < 1500) ? min(maxRounds, 6) : maxRounds
        guard round <= effectiveMax else {
            log("[Agent] 达到最大工具链轮数 \(effectiveMax) (memory-aware)")
            isProcessing = false
            return
        }

        // 重复检测 — 同名 tool 在【当前 user turn】内已跑过 ≥1 次 → 跳过本次执行,
        // 让模型继续推进. 只算"距离最后一条 user message 之间"的 skillResult,
        // 跨 turn 不算 (e.g. turn 1 fired reminders, turn 2 又 fire 是合法补参, 不是循环).
        let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) ?? -1
        let currentTurnSlice = lastUserIdx >= 0 ? Array(messages.suffix(from: lastUserIdx)) : Array(messages)
        let recentResults = currentTurnSlice.filter { $0.role == .skillResult }
        if let parsedCall = parseToolCall(fullText) {
            let candidateName = canonicalToolName(parsedCall.name, arguments: parsedCall.arguments)
            let sameNameCount = recentResults.filter {
                ($0.skillName ?? "") == candidateName
            }.count
            // load_skill 不应用此规则 — 模型可能合法地多次 load 不同 SKILL
            // (canonical 会把所有 load_skill 归一成同名, 易误判).
            if sameNameCount >= 1, candidateName != "load_skill" {
                log("[Agent] 检测到 tool \(candidateName) 已在前面跑过, skip 本次重复, 让模型继续")
                let lastResult = recentResults.last(where: { ($0.skillName ?? "") == candidateName })?.content ?? tr("已完成", "Done")
                let pseudoSummary = tr(
                    "[\(candidateName) 已经在前面成功执行, 不需要再调用. 请继续完成用户其他请求, 或给最终中文回复]\n上一次结果: \(lastResult)",
                    "[\(candidateName) has already executed successfully; do not invoke again. Continue with the user's other requests, or give the final answer in English.]\nLast result: \(lastResult)"
                )
                let followUpPrompt = PromptBuilder.appendToolResult(
                    toR1Prompt: prompt,
                    r1Output: fullText,
                    toolName: candidateName,
                    toolResultSummary: pseudoSummary
                )

                messages.append(ChatMessage(role: .assistant, content: "▍"))
                let followUpIndex = messages.count - 1

                guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
                    isProcessing = false
                    return
                }

                if parseToolCall(nextText) != nil {
                    messages[followUpIndex].update(content: "")
                    await executeToolChain(
                        prompt: followUpPrompt,
                        fullText: nextText,
                        userQuestion: userQuestion,
                        images: images,
                        round: round + 1,
                        maxRounds: maxRounds
                    )
                } else {
                    messages[followUpIndex].update(content: cleanOutput(nextText))
                    isProcessing = false
                }
                return
            }
        }

        guard let parsedCall = parseToolCall(fullText) else {
            let cleaned = cleanOutput(fullText)
            if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastAssistant].update(content: cleaned.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : cleaned)
            }
            isProcessing = false
            return
        }

        let call = (
            name: canonicalToolName(parsedCall.name, arguments: parsedCall.arguments),
            arguments: parsedCall.arguments
        )

        log("[Agent] Round \(round): tool_call name=\(call.name)")

        // ── list_skills ──
        if call.name == "list_skills" {
            let query = (call.arguments["query"] as? String ?? "").lowercased()
            let results = skillEntries.filter(\.isEnabled).filter { entry in
                guard !query.isEmpty else { return true }
                return entry.id.lowercased().contains(query)
                    || entry.name.lowercased().contains(query)
                    || entry.description.lowercased().contains(query)
            }
            let listing = results.map { "\($0.id): \($0.description)" }.joined(separator: "\n")
            let resultText = results.isEmpty
                ? tr("没有找到匹配「\(query)」的能力。",
                     "No abilities found matching \"\(query)\".")
                : tr("可用能力（\(results.count) 个）：\n\(listing)",
                     "Available abilities (\(results.count)):\n\(listing)")
            log("[Agent] list_skills query=\"\(query)\" results=\(results.count)")

            let toolResultSummary = toolResultSummaryForModel(toolName: "list_skills", toolResult: resultText)
            messages.append(ChatMessage(role: .skillResult, content: resultText, skillName: "list_skills"))

            // F3: R2 = R1 + R1 output + tool_result (continuation form).
            let followUpPrompt = PromptBuilder.appendToolResult(
                toR1Prompt: prompt,
                r1Output: fullText,
                toolName: "list_skills",
                toolResultSummary: toolResultSummary
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
                isProcessing = false
                return
            }

            if parseToolCall(nextText) != nil {
                log("[Agent] list_skills 后检测到 tool 调用 (round \(round + 1))")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, images: images, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                messages[followUpIndex].update(content: cleaned.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : cleaned)
                isProcessing = false
            }
            return
        }

        // ── load_skill ──
        if call.name == "load_skill" {
            let allCalls = parseAllToolCalls(fullText)
            let loadSkillCalls = allCalls.filter { $0.name == "load_skill" }

            var allInstructions = ""
            var loadedDisplayNames: [String] = []
            var loadedSkillIds: [String] = []
            for lsCall in loadSkillCalls {
                let requestedSkillName = (lsCall.arguments["skill"] as? String)
                             ?? (lsCall.arguments["name"] as? String)
                             ?? ""
                let skillName = skillRegistry.canonicalSkillId(for: requestedSkillName)
                log("[Agent] load_skill: \(requestedSkillName)")

                let displayName = findDisplayName(for: skillName)
                loadedDisplayNames.append(displayName)
                messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
                let cardIdx = messages.count - 1

                guard let instructions = handleLoadSkill(skillName: skillName) else {
                    messages[cardIdx].update(role: .system, content: "done", skillName: displayName)
                    continue
                }

                try? await Task.sleep(for: .milliseconds(300))
                messages[cardIdx].update(role: .system, content: "loaded", skillName: displayName)
                messages.append(ChatMessage(role: .skillResult, content: instructions, skillName: skillName))
                allInstructions += instructions + "\n\n"
                loadedSkillIds.append(skillName)
            }

            guard !allInstructions.isEmpty else {
                isProcessing = false
                return
            }

            if let autoCall = autoToolCallForLoadedSkills(skillIds: loadedSkillIds) {
                let syntheticToolCall = syntheticToolCallText(
                    name: autoCall.name,
                    arguments: autoCall.arguments
                )
                await executeToolChain(
                    prompt: prompt,
                    fullText: syntheticToolCall,
                    userQuestion: userQuestion,
                    images: images,
                    round: round + 1,
                    maxRounds: maxRounds
                )
                return
            }

            let singleToolExtraction = await extractToolCallForLoadedSkills(
                originalPrompt: prompt,
                userQuestion: userQuestion,
                skillInstructions: allInstructions,
                skillIds: loadedSkillIds,
                images: images
            )
            switch singleToolExtraction {
            case .toolCall(let name, let arguments):
                log("[Agent] load_skill 参数提取后执行工具: \(name)")
                let syntheticToolCall = syntheticToolCallText(name: name, arguments: arguments)
                await executeToolChain(
                    prompt: prompt,
                    fullText: syntheticToolCall,
                    userQuestion: userQuestion,
                    images: images,
                    round: round + 1,
                    maxRounds: maxRounds
                )
                return

            case .needsClarification(let clarification):
                messages.append(ChatMessage(role: .assistant, content: clarification))
                markSkillsDone(loadedDisplayNames)
                isProcessing = false
                return

            case .failed:
                break
            }

            // 计算所有 loaded skill 的 allowed-tools 并集 (去重)
            // — 这是 Scaffold T2 disclosure 的输入: 告诉模型哪些工具实际可调
            let availableTools: [String] = {
                var seen = Set<String>()
                var ordered: [String] = []
                for skillId in loadedSkillIds {
                    guard let def = skillRegistry.getDefinition(skillId) else { continue }
                    for toolName in def.metadata.allowedTools where !seen.contains(toolName) {
                        seen.insert(toolName)
                        ordered.append(toolName)
                    }
                }
                return ordered
            }()

            let followUpPrompt = PromptBuilder.buildLoadedSkillPrompt(
                originalPrompt: prompt,
                userQuestion: userQuestion,
                skillInstructions: allInstructions,
                availableTools: availableTools,
                includeTimeAnchor: requiresTimeAnchor(forSkillIds: loadedSkillIds),
                currentImageCount: images.count
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
                isProcessing = false
                return
            }

            if parseToolCall(nextText) != nil {
                log("[Agent] load_skill 后检测到 tool 调用 (round \(round + 1))")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, images: images, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                if cleaned.isEmpty
                    || looksLikeStructuredIntermediateOutput(cleaned)
                    || looksLikePromptEcho(cleaned) {
                    let retryPrompt = PromptBuilder.buildLoadedSkillPrompt(
                        originalPrompt: prompt,
                        userQuestion: userQuestion,
                        skillInstructions: allInstructions,
                        availableTools: availableTools,
                        includeTimeAnchor: requiresTimeAnchor(forSkillIds: loadedSkillIds),
                        currentImageCount: images.count,
                        forceResponse: true
                    )

                    guard let retryText = await streamLLM(prompt: retryPrompt, msgIndex: followUpIndex, images: images) else {
                        isProcessing = false
                        return
                    }

                    if parseToolCall(retryText) != nil {
                        log("[Agent] load_skill 重试后检测到 tool 调用 (round \(round + 1))")
                        messages[followUpIndex].update(content: "")
                        await executeToolChain(
                            prompt: retryPrompt,
                            fullText: retryText,
                            userQuestion: userQuestion,
                            images: images,
                            round: round + 1,
                            maxRounds: maxRounds
                        )
                    } else {
                        let retryCleaned = cleanOutput(retryText)
                        let loadedSkillName = loadedDisplayNames.joined(separator: ", ").isEmpty
                            ? tr("已加载的能力", "loaded ability")
                            : loadedDisplayNames.joined(separator: ", ")
                        let finalReply = retryCleaned.isEmpty
                            || looksLikeStructuredIntermediateOutput(retryCleaned)
                            || looksLikePromptEcho(retryCleaned)
                            ? fallbackReplyForEmptySkillFollowUp(skillName: loadedSkillName)
                            : retryCleaned
                        messages[followUpIndex].update(content: finalReply)
                        markSkillsDone(loadedDisplayNames)
                        isProcessing = false
                    }
                } else {
                    messages[followUpIndex].update(content: cleaned)
                    markSkillsDone(loadedDisplayNames)
                    isProcessing = false
                }
            }
            return
        }

        // ── 具体 Tool 调用 ──

        let ownerSkillId = findSkillId(for: call.name)
        let displayName = findDisplayName(for: call.name)

        let cardIndex: Int
        if let idx = messages.lastIndex(where: {
            $0.role == .system && ($0.skillName == displayName || $0.skillName == call.name)
            && ($0.content == "identified" || $0.content == "loaded")
        }) {
            cardIndex = idx
        } else {
            messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
            cardIndex = messages.count - 1
        }

        guard ownerSkillId != nil else {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: tr(
                "⚠️ 未知工具: \(call.name)",
                "⚠️ Unknown tool: \(call.name)"
            )))
            isProcessing = false
            return
        }

        let enabledIds = Set(skillEntries.filter(\.isEnabled).map(\.id))
        guard enabledIds.contains(ownerSkillId!) else {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: tr(
                "⚠️ Skill \(displayName) 未启用",
                "⚠️ Skill \(displayName) is not enabled"
            )))
            isProcessing = false
            return
        }

        messages[cardIndex].update(role: .system, content: "executing:\(call.name)", skillName: displayName)

        do {
            let canonicalResult: CanonicalToolResult
            let toolResultDetail: String
            if HotfixFeatureFlags.useHotfixPromptPipeline && HotfixFeatureFlags.enableCanonicalToolResult {
                canonicalResult = try await handleToolExecutionCanonical(toolName: call.name, args: call.arguments)
                toolResultDetail = canonicalResult.detail
            } else {
                let toolResult = try await handleToolExecution(toolName: call.name, args: call.arguments)
                canonicalResult = canonicalToolResult(toolName: call.name, toolResult: toolResult)
                toolResultDetail = toolResult
            }
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .skillResult, content: toolResultDetail, skillName: call.name))
            log("[Agent] Tool \(call.name) round \(round) done")

            if toolRegistry.shouldSkipFollowUp(for: call.name) {
                messages.append(ChatMessage(role: .assistant, content: canonicalResult.summary))
                isProcessing = false
                return
            }

            // F3: R2 prompt = R1 prompt + R1 output + tool_result message.
            // 物理上是 R1 conversation 的延伸 → KV cache 自然命中 R1 全部 token.
            let followUpPrompt = PromptBuilder.appendToolResult(
                toR1Prompt: prompt,
                r1Output: fullText,
                toolName: call.name,
                toolResultSummary: canonicalResult.summary
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
                isProcessing = false
                return
            }

            if !parseAllToolCalls(nextText).isEmpty {
                log("[Agent] 检测到第 \(round + 1) 轮工具调用")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, images: images, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                if cleaned.isEmpty
                    || looksLikeStructuredIntermediateOutput(cleaned)
                    || looksLikePromptEcho(cleaned) {
                    messages[followUpIndex].update(content: fallbackReplyForEmptyToolFollowUp(
                        toolName: call.name,
                        toolResultSummary: canonicalResult.summary,
                        toolResultDetail: toolResultDetail
                    ))
                } else {
                    messages[followUpIndex].update(content: cleaned)
                }
                isProcessing = false
            }
        } catch {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .system, content: tr(
                "❌ Tool 执行失败: \(error)",
                "❌ Tool execution failed: \(error)"
            )))
            isProcessing = false
        }
    }
}
