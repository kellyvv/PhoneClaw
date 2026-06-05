import CoreImage
import Foundation

// MARK: - ToolChain 内部数据类型

enum SingleToolExtractionOutcome {
    case toolCall(name: String, arguments: [String: Any])
    case needsClarification(String)
    case failed
}

private struct PhoneGroundAnswerValidation {
    let issues: [String]
    let shouldTryAlternativeFetch: Bool

    var shouldRepair: Bool {
        !issues.isEmpty
    }
}

private struct PhoneGroundPayloadValidation {
    let issues: [String]

    var isValid: Bool {
        issues.isEmpty
    }
}

private struct PhoneGroundPayloadNormalization {
    let detail: String
    let recoveredIssues: [String]
    let remainingIssues: [String]
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

    private func modelPlannedWebQueries(
        userQuestion: String,
        initialQuery: String,
        images: [CIImage]
    ) async -> [String] {
        let trimmedQuestion = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty || !trimmedQuery.isEmpty else {
            return []
        }

        let prompt = PromptBuilder.buildWebQueryPlanPrompt(
            userQuestion: trimmedQuestion.isEmpty ? trimmedQuery : trimmedQuestion,
            initialQuery: trimmedQuery.isEmpty ? trimmedQuestion : trimmedQuery,
            currentImageCount: images.count
        )
        guard let raw = await streamLLM(prompt: prompt, images: images),
              let payload = parseJSONObject(raw) ?? parseJSONObject(cleanOutput(raw)) else {
            return []
        }

        let rawQueries = (payload["queries"] as? [Any])?.compactMap { $0 as? String } ?? []
        let cleanedQueries = sanitizedWebQueryPlan(
            rawQueries,
            userQuestion: trimmedQuestion,
            initialQuery: trimmedQuery
        )
        if !cleanedQueries.isEmpty {
            log("[Agent] web-search model query plan: \(cleanedQueries.joined(separator: " | "))")
        }
        return cleanedQueries
    }

    private func sanitizedWebQueryPlan(
        _ queries: [String],
        userQuestion: String,
        initialQuery: String
    ) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for query in queries {
            let normalized = query
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 2, normalized.count <= 120 else {
                continue
            }
            guard !normalized.contains("<tool_call>"),
                  !normalized.contains("{"),
                  !normalized.contains("}") else {
                continue
            }
            let key = normalized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(normalized)
            if output.count >= 4 { break }
        }

        let fallback = initialQuery.isEmpty ? userQuestion : initialQuery
        if output.isEmpty, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [fallback.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return output
    }

    private func modelReplannedWebQueries(
        userQuestion: String,
        previousSearchDetail: String,
        images: [CIImage]
    ) async -> [String] {
        guard webSearchResultNeedsReplan(previousSearchDetail) else {
            return []
        }

        let prompt = PromptBuilder.buildWebQueryReplanPrompt(
            userQuestion: userQuestion,
            previousSearchSummary: compactWebSearchDetailForReplan(previousSearchDetail),
            currentImageCount: images.count
        )
        guard let raw = await streamLLM(prompt: prompt, images: images),
              let payload = parseJSONObject(raw) ?? parseJSONObject(cleanOutput(raw)) else {
            return []
        }

        let previousQueries = Set(webSearchQueries(fromDetail: previousSearchDetail).map { $0.lowercased() })
        let rawQueries = (payload["queries"] as? [Any])?.compactMap { $0 as? String } ?? []
        let cleanedQueries = sanitizedWebQueryPlan(
            rawQueries,
            userQuestion: userQuestion,
            initialQuery: userQuestion
        )
        .filter { !previousQueries.contains($0.lowercased()) }

        if !cleanedQueries.isEmpty {
            log("[Agent] web-search replan queries: \(cleanedQueries.joined(separator: " | "))")
        }
        return Array(cleanedQueries.prefix(4))
    }

    private func retryWebSearchWithReplannedQueriesIfNeeded(
        searchDetail: String,
        userQuestion: String,
        images: [CIImage]
    ) async -> CanonicalToolResult? {
        let queries = await modelReplannedWebQueries(
            userQuestion: userQuestion,
            previousSearchDetail: searchDetail,
            images: images
        )
        guard !queries.isEmpty else { return nil }

        do {
            let result = try await handleToolExecutionCanonical(
                toolName: "web-search",
                args: [
                    "query": queries.first ?? userQuestion,
                    "question": userQuestion,
                    "planned_queries": queries,
                    "max_results": 6
                ]
            )
            log("[Agent] web-search second-pass completed queries=\(queries.count)")
            return result
        } catch {
            log("[Agent] web-search second-pass failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func webSearchResultNeedsReplan(_ detail: String) -> Bool {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (payload["success"] as? Bool) == true else {
            return false
        }

        if payload["answerability"] as? String == "direct" {
            return false
        }
        if payload["direct_evidence_sufficient"] as? Bool == true {
            return false
        }
        if let evidencePack = payload["evidence_pack"] as? [String: Any] {
            if evidencePack["sufficiency"] as? String == "sufficient" {
                return false
            }
            let chunkCount = (evidencePack["chunk_count"] as? Int)
                ?? ((evidencePack["chunks"] as? [[String: Any]])?.count ?? 0)
            let fetchedCount = evidencePack["fetched_document_count"] as? Int ?? 0
            if chunkCount >= 2 && fetchedCount > 0 {
                return false
            }
        }

        let directCount = payload["direct_answer_result_count"] as? Int ?? 0
        return directCount == 0 || (payload["answerability"] as? String) == "needs_fetch"
    }

    private func webSearchQueries(fromDetail detail: String) -> [String] {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryPlan = payload["query_plan"] as? [String: Any] else {
            return []
        }
        return (queryPlan["queries"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func compactWebSearchDetailForReplan(_ detail: String) -> String {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return detail
        }
        var lines: [String] = []
        if let queryPlan = payload["query_plan"] as? [String: Any] {
            let queries = (queryPlan["queries"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !queries.isEmpty {
                lines.append("queries: \(queries.joined(separator: " | "))")
            }
            if let planner = queryPlan["planner"] as? String {
                lines.append("planner: \(planner)")
            }
        }
        if let answerability = payload["answerability"] as? String {
            lines.append("answerability: \(answerability)")
        }
        if let evidencePack = payload["evidence_pack"] as? [String: Any] {
            let sufficiency = evidencePack["sufficiency"] as? String ?? "unknown"
            let chunkCount = (evidencePack["chunk_count"] as? Int)
                ?? ((evidencePack["chunks"] as? [[String: Any]])?.count ?? 0)
            lines.append("evidence_pack: sufficiency=\(sufficiency), chunks=\(chunkCount)")
        }
        if let results = payload["results"] as? [[String: Any]] {
            let resultLines = results.prefix(6).enumerated().map { index, result in
                let title = (result["title"] as? String) ?? ""
                let host = (result["host"] as? String) ?? ""
                let confidence = (result["confidence"] as? String) ?? ""
                let needsFetch = (result["needs_fetch"] as? Bool) == true
                return "\(index + 1). \(title) host=\(host) confidence=\(confidence) needs_fetch=\(needsFetch)"
            }
            lines.append("results:\n\(resultLines.joined(separator: "\n"))")
        }
        return lines.isEmpty ? detail : lines.joined(separator: "\n")
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

    func canFallbackToPreloadedSkillTool(skillIds: [String]) -> Bool {
        if autoToolCallForLoadedSkills(skillIds: skillIds) != nil {
            return true
        }

        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds
        guard uniqueSkillIds.count == 1,
              let skillId = uniqueSkillIds.first else {
            return false
        }

        return registeredTools(for: skillId).contains { !$0.isParameterless }
    }

    func compactSkillInstructionsForToolFallback(
        skillIds: [String],
        preloadedSkills: [PromptBuilder.PreloadedSkill]
    ) -> String {
        let preloadedById = Dictionary(uniqueKeysWithValues: preloadedSkills.map { ($0.id, $0) })
        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds

        return uniqueSkillIds.compactMap { skillId -> String? in
            let displayName =
                preloadedById[skillId]?.displayName
                ?? skillRegistry.getDefinition(skillId)?.metadata.name
                ?? skillId
            let tools = registeredTools(for: skillId)
            let toolTuples = tools.map {
                (
                    name: $0.name,
                    description: $0.description,
                    parameters: $0.parameters,
                    requiredParameters: $0.requiredParameters
                )
            }
            let schema = PromptBuilder.PreloadedSkill.makeCompactSchema(
                skillName: displayName,
                tools: toolTuples
            )
            return "Skill: \(displayName)\n\(schema)"
        }
        .joined(separator: "\n\n")
    }

    func executePreloadedSkillToolFallback(
        extractionPromptBase: String,
        toolChainPrompt: String,
        userQuestion: String,
        skillIds: [String],
        preloadedSkills: [PromptBuilder.PreloadedSkill],
        images: [CIImage],
        msgIndex: Int,
        fallbackText: String
    ) async {
        let skillInstructions = compactSkillInstructionsForToolFallback(
            skillIds: skillIds,
            preloadedSkills: preloadedSkills
        )
        guard !skillInstructions.isEmpty else {
            let finalReply = fallbackReplyAfterPreloadedSkillFallbackFailure(fallbackText)
            if messages.indices.contains(msgIndex) {
                messages[msgIndex].update(content: finalReply)
            }
            finishTurn()
            return
        }

        if let autoCall = autoToolCallForLoadedSkills(skillIds: skillIds) {
            log("[Agent] preloaded skill fallback auto tool: \(autoCall.name)")
            let syntheticToolCall = syntheticToolCallText(
                name: autoCall.name,
                arguments: autoCall.arguments
            )
            await executeToolChain(
                prompt: toolChainPrompt,
                fullText: syntheticToolCall,
                userQuestion: userQuestion,
                images: images
            )
            return
        }

        let extraction = await extractToolCallForLoadedSkills(
            originalPrompt: extractionPromptBase,
            userQuestion: userQuestion,
            skillInstructions: skillInstructions,
            skillIds: skillIds,
            images: images
        )

        switch extraction {
        case .toolCall(let name, let arguments):
            log("[Agent] preloaded skill fallback extracted tool: \(name)")
            let syntheticToolCall = syntheticToolCallText(name: name, arguments: arguments)
            await executeToolChain(
                prompt: toolChainPrompt,
                fullText: syntheticToolCall,
                userQuestion: userQuestion,
                images: images
            )

        case .needsClarification(let clarification):
            if messages.indices.contains(msgIndex) {
                messages[msgIndex].update(content: clarification)
            }
            finishTurn()

        case .failed:
            log("[Agent] preloaded skill fallback extraction failed")
            let finalReply = fallbackReplyAfterPreloadedSkillFallbackFailure(fallbackText)
            if messages.indices.contains(msgIndex) {
                messages[msgIndex].update(content: finalReply)
            }
            finishTurn()
        }
    }

    func fallbackReplyAfterPreloadedSkillFallbackFailure(_ fallbackText: String) -> String {
        let cleaned = cleanOutput(fallbackText)
        if cleaned.isEmpty
            || looksLikeStructuredIntermediateOutput(cleaned)
            || looksLikePromptEcho(cleaned) {
            return PromptLocale.current.emptyReplyPlaceholder
        }
        return cleaned
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
        if usesGroundedSourcesContract(toolName) {
            return groundedFallbackReplyForEmptyToolFollowUp(
                toolName: toolName,
                toolResultSummary: summary,
                toolResultDetail: trimmed
            )
        }
        if !summary.isEmpty, summary != trimmed {
            return summary
        }

        if trimmed.isEmpty {
            return tr(
                "已完成，但没有返回可展示的内容。",
                "Done, but there was no displayable result."
            )
        }

        if LanguageService.shared.current.isChinese {
            return """
            已完成，不过我没能整理出自然回复。
            结果如下：
            \(trimmed)
            """
        } else {
            return """
            Done, but I could not compose a natural reply.
            Result:
            \(trimmed)
            """
        }
    }

    private func groundedFallbackReplyForEmptyToolFollowUp(
        toolName: String,
        toolResultSummary: String,
        toolResultDetail: String
    ) -> String {
        let summaryText = bestEvidenceSnippet(fromToolResultDetail: toolResultDetail)
            ?? removeInlineWebLinks(removeExistingSourceSection(toolResultSummary))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let clippedSummary = clippedPlainText(summaryText, maxCharacters: 420)
        let body: String
        if clippedSummary.isEmpty {
            body = tr(
                "总结\n这次工具返回了可检查的来源，但没有稳定生成自然语言结论。请优先打开下方来源核对最新信息。",
                "Summary\nThe tool returned checkable sources, but a natural-language conclusion was not generated reliably. Please verify the latest information from the sources below."
            )
        } else if LanguageService.shared.current.isChinese {
            body = "总结\n我找到了可用的搜索证据。最相关证据显示：\(clippedSummary)"
        } else {
            body = "Summary\nI found usable search evidence. The most relevant evidence says: \(clippedSummary)"
        }

        return appendSourceCitationIfNeeded(
            to: body,
            toolName: toolName,
            toolResultDetail: toolResultDetail
        )
    }

    private func bestEvidenceSnippet(fromToolResultDetail detail: String) -> String? {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let evidencePack = payload["evidence_pack"] as? [String: Any],
              let chunks = evidencePack["chunks"] as? [[String: Any]] else {
            return nil
        }

        let sortedChunks = chunks.sorted { lhs, rhs in
            let lhsScore = lhs["score"] as? Double ?? 0
            let rhsScore = rhs["score"] as? Double ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return ((lhs["source_rank"] as? Int) ?? Int.max) < ((rhs["source_rank"] as? Int) ?? Int.max)
        }
        return sortedChunks
            .compactMap { $0["text"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func clippedPlainText(_ text: String, maxCharacters: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: maxCharacters)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    func shouldUseCompactToolFollowUp(
        _ prompt: String,
        toolName: String? = nil
    ) -> Bool {
        if let toolName, Self.prefersCompactToolFollowUp(toolName: toolName) {
            log("[Agent] tool follow-up compact prompt: tool=\(toolName)")
            return true
        }

        let estimatedPromptTokens = PromptTokenEstimator.estimate(prompt)
        let reservedOutputTokens = min(
            inference.maxOutputTokens,
            selectedModelCapabilities.defaultReservedOutputTokens
        )
        let budget = selectedModelCapabilities.safeContextBudgetTokens
        let shouldCompact = estimatedPromptTokens + reservedOutputTokens > budget
        if shouldCompact {
            log("[Agent] tool follow-up compact prompt: estimated=\(estimatedPromptTokens) reserved=\(reservedOutputTokens) budget=\(budget)")
        }
        return shouldCompact
    }

    private static func prefersCompactToolFollowUp(toolName: String) -> Bool {
        switch toolName {
        case "web-search", "web-fetch":
            return true
        default:
            return false
        }
    }

    func fallbackReplyForEmptySkillFollowUp(skillName: String) -> String {
        tr(
            "我已经准备好这项能力了，但还缺少下一步。请把需求说得更具体一些。",
            "I'm ready to use this capability, but I need a more specific request."
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

    func appendSourceCitationIfNeeded(
        to answer: String,
        toolName: String,
        toolResultDetail: String
    ) -> String {
        guard usesGroundedSourcesContract(toolName) else {
            return answer
        }
        let urls = sourceURLs(fromToolResultDetail: toolResultDetail) + sourceURLs(fromAnswerText: answer)
        guard !urls.isEmpty else { return answer }

        let uniqueURLs = uniqueSourceURLs(urls)
        let cleanedAnswer = removeInlineSourceParentheticals(answer)
        let bodyAnswer = removeInlineWebLinks(removeExistingSourceSection(cleanedAnswer))
        let sources = sourceSection(for: uniqueURLs)
        guard !sources.isEmpty else { return bodyAnswer }
        return bodyAnswer.isEmpty ? sources : bodyAnswer + "\n\n" + sources
    }

    private func finalizeWebAnswer(
        _ answer: String,
        toolName: String,
        toolResultSummary: String,
        toolResultDetail: String,
        userQuestion: String,
        images: [CIImage],
        msgIndex: Int
    ) async -> String {
        guard usesGroundedSourcesContract(toolName) else {
            return answer
        }

        let normalized = appendSourceCitationIfNeeded(
            to: answer,
            toolName: toolName,
            toolResultDetail: toolResultDetail
        )
        let validation = validateGroundedWebAnswer(
            normalized,
            toolName: toolName,
            toolResultDetail: toolResultDetail
        )
        guard validation.shouldRepair else {
            return normalized
        }

        log("[Agent] web answer repair needed: \(validation.issues.joined(separator: "; "))")
        let repairPrompt = PromptBuilder.buildWebAnswerRepairPrompt(
            userQuestion: userQuestion,
            toolName: toolName,
            toolResultSummary: toolResultSummary,
            draftAnswer: normalized,
            validationIssues: validation.issues,
            currentImageCount: images.count
        )
        guard let repairedText = await streamLLM(prompt: repairPrompt, msgIndex: msgIndex, images: images) else {
            return normalized
        }

        let repaired = cleanOutput(repairedText)
        guard !repaired.isEmpty,
              !looksLikeStructuredIntermediateOutput(repaired),
              !looksLikePromptEcho(repaired) else {
            return normalized
        }

        let repairedNormalized = appendSourceCitationIfNeeded(
            to: repaired,
            toolName: toolName,
            toolResultDetail: toolResultDetail
        )
        let repairedValidation = validateGroundedWebAnswer(
            repairedNormalized,
            toolName: toolName,
            toolResultDetail: toolResultDetail
        )
        return repairedValidation.issues.count <= validation.issues.count
            ? repairedNormalized
            : normalized
    }

    private func sourceURLs(fromToolResultDetail detail: String) -> [String] {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var urls: [String] = []
        if let url = payload["url"] as? String, !url.isEmpty {
            urls.append(url)
        }

        if let evidencePack = payload["evidence_pack"] as? [String: Any],
           let chunks = evidencePack["chunks"] as? [[String: Any]] {
            let sortedChunks = chunks.sorted { lhs, rhs in
                let lhsScore = lhs["score"] as? Double ?? 0
                let rhsScore = rhs["score"] as? Double ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return ((lhs["source_rank"] as? Int) ?? Int.max) < ((rhs["source_rank"] as? Int) ?? Int.max)
            }
            for chunk in sortedChunks {
                if let url = chunk["url"] as? String, !url.isEmpty {
                    urls.append(url)
                }
            }
        }

        if let results = payload["results"] as? [[String: Any]] {
            let sortedResults = results.sorted { lhs, rhs in
                let lhsRank = sourcePriority(lhs)
                let rhsRank = sourcePriority(rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return ((lhs["rank"] as? Int) ?? Int.max) < ((rhs["rank"] as? Int) ?? Int.max)
            }
            for result in sortedResults {
                if let url = result["url"] as? String, !url.isEmpty {
                    urls.append(url)
                }
            }
        }

        return uniqueSourceURLs(urls)
    }

    private func uniqueSourceURLs(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.filter { rawURL in
            let url = normalizedSourceURL(rawURL)
            guard !url.isEmpty else { return false }
            let key = normalizedSourceKey(url)
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }.map(normalizedSourceURL)
    }

    private func sourceURLs(fromAnswerText answer: String) -> [String] {
        let sourcePatterns = [
            #"\]\((https?://[^\s)]+)\)"#,
            #"(https?://[^\s\]\)）>，。；;、]+)"#,
            #"(?:来源|Source)\s*[:：]\s*((?:https?://|www\.)[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+)"#,
            #"(?:来源|Source)\s*[:：]\s*([A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s）),，。；;]*)?)"#,
            #"(?<![@/:])\b((?:www\.)[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s\]\)）>，。；;、]*)?)"#
        ]
        var urls: [String] = []
        let nsAnswer = answer as NSString
        for pattern in sourcePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let matches = regex.matches(
                in: answer,
                range: NSRange(location: 0, length: nsAnswer.length)
            )
            for match in matches where match.numberOfRanges >= 2 {
                let raw = nsAnswer.substring(with: match.range(at: 1))
                urls.append(normalizedSourceURL(raw))
            }
        }
        return uniqueSourceURLs(urls)
    }

    private func normalizedSourceURL(_ rawURL: String) -> String {
        var url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = CharacterSet(charactersIn: "）).,，。；;、")
        url = url.trimmingCharacters(in: trailing)
        guard !url.isEmpty else { return "" }
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return url
        }
        return "https://\(url)"
    }

    private func isLowValueSourceURL(_ rawURL: String) -> Bool {
        let normalized = normalizedSourceURL(rawURL).lowercased()
        return normalized == "https://example.com" || normalized == "http://example.com"
    }

    private func sourcePriority(_ result: [String: Any]) -> Int {
        if result["query_relevant"] as? Bool == false { return 10 }
        if result["directly_usable"] as? Bool == true { return 0 }
        if result["needs_fetch"] as? Bool == false { return 1 }
        if result["confidence"] as? String == "low" { return 3 }
        return 2
    }

    private func removeExistingSourceSection(_ answer: String) -> String {
        var output: [String] = []
        for line in answer.components(separatedBy: "\n") {
            if isSourceSectionHeading(line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                break
            }
            output.append(line)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitWebAnswerSections(_ answer: String) -> (body: String, sources: String?) {
        var body: [String] = []
        var sources: [String] = []
        var inSources = false
        for line in answer.components(separatedBy: "\n") {
            if isSourceSectionHeading(line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                inSources = true
            }
            if inSources {
                sources.append(line)
            } else {
                body.append(line)
            }
        }
        let sourceText = sources.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            sourceText.isEmpty ? nil : sourceText
        )
    }

    private func sourceSection(for urls: [String]) -> String {
        let filteredURLs = urls.filter { !isLowValueSourceURL($0) }
        guard !filteredURLs.isEmpty else { return "" }
        let lines = filteredURLs.prefix(5).enumerated().map { index, url in
            "\(index + 1). [\(sourceLabel(for: url))](\(url))"
        }.joined(separator: "\n")
        return tr("引用网址\n\(lines)", "Sources\n\(lines)")
    }

    private func sourceLabel(for rawURL: String) -> String {
        guard let url = URL(string: rawURL),
              let host = url.host,
              !host.isEmpty else {
            return rawURL.replacingOccurrences(of: "]", with: "")
        }
        let label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return label.replacingOccurrences(of: "]", with: "")
    }

    private func removeInlineSourceParentheticals(_ answer: String) -> String {
        var result = answer
        let patterns = [
            #"（\s*(来源|Source)\s*[:：][^）]{0,260}）"#,
            #"\(\s*(来源|Source)\s*[:：][^)]{0,260}\)"#,
            #"\s*(来源|Source)\s*[:：]\s*(?:https?://|www\.)[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#,
            #"\s*(来源|Source)\s*[:：]\s*[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s）),，。；;]*)?"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: ""
            )
        }
        result = result.replacingOccurrences(of: #" +([，。；：,.!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([）)])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[（(]\s*[）)]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeInlineWebLinks(_ answer: String) -> String {
        var result = answer
        result = result.replacingOccurrences(
            of: #"\[([^\]\n]{1,120})\]\(https?://[^\s)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"https?://[^\s\]\)）>，。；;、]+"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?<![@/:])\bwww\.[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s\]\)）>，。；;、]*)?"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" +([，。；：,.!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSourceSectionHeading(_ text: String) -> Bool {
        var normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("#") {
            normalized.removeFirst()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized == "引用网址"
            || normalized == "引用链接"
            || normalized == "sources"
            || normalized == "references"
            || normalized.hasPrefix("引用网址：")
            || normalized.hasPrefix("引用链接：")
            || normalized.hasPrefix("sources:")
            || normalized.hasPrefix("references:")
    }

    private func validateGroundedWebAnswer(
        _ answer: String,
        toolName: String,
        toolResultDetail: String
    ) -> PhoneGroundAnswerValidation {
        guard usesGroundedSourcesContract(toolName) else {
            return PhoneGroundAnswerValidation(issues: [], shouldTryAlternativeFetch: false)
        }

        let sections = splitWebAnswerSections(answer)
        let body = sections.body
        let sources = sections.sources ?? ""
        let expectedURLs = sourceURLs(fromToolResultDetail: toolResultDetail)
            .filter { !isLowValueSourceURL($0) }
        var issues: [String] = []

        if body.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
            issues.append(tr("总结正文为空或过短。", "Summary body is empty or too short."))
        }
        if webAnswerContainsPlaceholder(answer) {
            issues.append(tr("回答包含占位符或模板文本。", "Answer contains placeholder or template text."))
        }
        if groundedAnswerLanguageMismatch(body) {
            issues.append(tr(
                "回答语言与当前会话语言不一致。",
                "Answer language does not match the current conversation language."
            ))
        }
        if !expectedURLs.isEmpty {
            if sections.sources == nil {
                issues.append(tr("缺少独立的“引用网址”段。", "Missing separate Sources section."))
            } else if markdownLinkCount(in: sources) == 0 {
                issues.append(tr("引用网址段没有 Markdown 可点击链接。", "Sources section has no clickable Markdown links."))
            }
        }
        if !sourceURLs(fromAnswerText: body).isEmpty {
            issues.append(tr("总结正文仍混入 URL 或来源链接。", "Summary body still contains URLs or source links."))
        }
        if bodyContainsInlineSourceMarker(body) {
            issues.append(tr("总结正文仍混入来源括号或来源标记。", "Summary body still contains inline source markers."))
        }

        let hasUsableEvidence = webToolDetailHasUsableEvidence(toolResultDetail)
        let insufficientAnswer = webAnswerLooksInsufficient(body)
        if hasUsableEvidence && insufficientAnswer {
            issues.append(tr("工具结果已有可用证据，但回答仍说证据不足。", "Tool result has usable evidence, but the answer still claims insufficient evidence."))
        }

        return PhoneGroundAnswerValidation(
            issues: issues,
            shouldTryAlternativeFetch: toolName == "web-fetch" && insufficientAnswer
        )
    }

    private func groundedAnswerLanguageMismatch(_ body: String) -> Bool {
        let cleaned = body
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"`[^`]+`"#, with: " ", options: .regularExpression)
        let cjkCount = cleaned.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }.count

        if LanguageService.shared.current.isChinese {
            return cjkCount < 6
        }

        let latinWords = regexMatchCount(pattern: #"\b[A-Za-z][A-Za-z'-]{2,}\b"#, in: cleaned)
        let cjkLimit = max(12, cleaned.count / 20)
        return latinWords < 5 || cjkCount > cjkLimit
    }

    private func usesGroundedSourcesContract(_ toolName: String) -> Bool {
        toolRegistry.answerContract(for: toolName) == .groundedSources
    }

    func normalizePhoneGroundPayloadIfNeeded(toolName: String, detail: String) -> String {
        normalizePhoneGroundPayload(toolName: toolName, detail: detail).detail
    }

    @discardableResult
    private func validatePhoneGroundPayloadIfNeeded(toolName: String, detail: String) -> PhoneGroundPayloadValidation {
        let normalized = normalizePhoneGroundPayload(toolName: toolName, detail: detail)
        return PhoneGroundPayloadValidation(issues: normalized.remainingIssues)
    }

    private func normalizePhoneGroundPayload(
        toolName: String,
        detail: String
    ) -> PhoneGroundPayloadNormalization {
        guard let contract = toolRegistry.phoneGroundContract(for: toolName),
              contract.answerContract != .none else {
            return PhoneGroundPayloadNormalization(detail: detail, recoveredIssues: [], remainingIssues: [])
        }

        guard let payload = phoneGroundPayloadDictionary(from: detail) else {
            let issues = ["payload is not JSON"]
            log("[PhoneGround] contract issues tool=\(toolName) issues=\(issues.joined(separator: "; "))")
            return PhoneGroundPayloadNormalization(detail: detail, recoveredIssues: [], remainingIssues: issues)
        }

        let originalValidation = validatePhoneGroundPayload(toolName: toolName, contract: contract, payload: payload)
        var normalizedPayload = payload
        var recoveredIssues: [String] = []

        if normalizedPayload["phone_ground"] as? [String: Any] == nil {
            normalizedPayload["phone_ground"] = synthesizedPhoneGroundMetadata(for: contract, payload: payload)
            recoveredIssues.append("missing phone_ground metadata")
        }

        if var evidencePack = normalizedPayload["evidence_pack"] as? [String: Any],
           evidencePack["phone_ground"] as? [String: Any] == nil {
            evidencePack["phone_ground"] = synthesizedPhoneGroundMetadata(for: contract, payload: payload)
            normalizedPayload["evidence_pack"] = evidencePack
        }

        if contract.answerContract == .groundedDataSummary,
           (normalizedPayload["success"] as? Bool) == true,
           normalizedPayload["evidence_pack"] as? [String: Any] == nil,
           let evidencePack = synthesizedDataEvidencePack(for: contract, payload: normalizedPayload) {
            normalizedPayload["evidence_pack"] = evidencePack
            recoveredIssues.append("groundedDataSummary missing evidence_pack")
        }

        let normalizedDetail = jsonString(normalizedPayload)
        let normalizedValidation = validatePhoneGroundPayload(
            toolName: toolName,
            contract: contract,
            detail: normalizedDetail
        )

        if !recoveredIssues.isEmpty, normalizedValidation.isValid {
            log("[PhoneGround] recovered tool=\(toolName) issues=\(recoveredIssues.joined(separator: "; "))")
            return PhoneGroundPayloadNormalization(
                detail: normalizedDetail,
                recoveredIssues: recoveredIssues,
                remainingIssues: []
            )
        }

        guard normalizedValidation.isValid else {
            let issues = normalizedValidation.issues
            log("[PhoneGround] contract issues tool=\(toolName) issues=\(issues.joined(separator: "; "))")
            normalizedPayload["phone_ground_validation"] = [
                "status": "invalid",
                "issues": issues,
                "recovered_issues": recoveredIssues
            ]
            return PhoneGroundPayloadNormalization(
                detail: jsonString(normalizedPayload),
                recoveredIssues: recoveredIssues,
                remainingIssues: issues
            )
        }

        return PhoneGroundPayloadNormalization(
            detail: originalValidation.isValid ? detail : normalizedDetail,
            recoveredIssues: recoveredIssues,
            remainingIssues: []
        )
    }

    private func validatePhoneGroundPayload(
        toolName: String,
        contract: PhoneGroundToolContract,
        detail: String
    ) -> PhoneGroundPayloadValidation {
        guard let payload = phoneGroundPayloadDictionary(from: detail) else {
            return PhoneGroundPayloadValidation(issues: ["payload is not JSON"])
        }

        return validatePhoneGroundPayload(toolName: toolName, contract: contract, payload: payload)
    }

    private func validatePhoneGroundPayload(
        toolName: String,
        contract: PhoneGroundToolContract,
        payload: [String: Any]
    ) -> PhoneGroundPayloadValidation {
        var issues: [String] = []
        let topMetadata = payload["phone_ground"] as? [String: Any]
        let evidencePack = payload["evidence_pack"] as? [String: Any]
        let evidenceMetadata = evidencePack?["phone_ground"] as? [String: Any]
        let metadata = topMetadata ?? evidenceMetadata

        guard let metadata else {
            return PhoneGroundPayloadValidation(issues: ["missing phone_ground metadata"])
        }

        let allowedEvidenceTypes = Set(contract.evidenceTypes.map(\.rawValue))
        let evidenceType = metadata["evidence_type"] as? String
        if evidenceType.map({ allowedEvidenceTypes.contains($0) }) != true {
            issues.append("evidence_type expected \(allowedEvidenceTypes.sorted()), got \(evidenceType ?? "nil")")
        }

        let answerContract = metadata["answer_contract"] as? String
        if answerContract != contract.answerContract.rawValue {
            issues.append("answer_contract expected \(contract.answerContract.rawValue), got \(answerContract ?? "nil")")
        }

        if contract.freshness != .unspecified,
           let freshness = metadata["freshness"] as? String,
           freshness != contract.freshness.rawValue {
            issues.append("freshness expected \(contract.freshness.rawValue), got \(freshness)")
        }

        if let success = payload["success"] as? Bool, success {
            switch contract.answerContract {
            case .groundedSources:
                if sourceURLs(fromToolResultDetail: jsonString(payload)).isEmpty {
                    issues.append("groundedSources payload has no source URL")
                }
            case .groundedDataSummary:
                guard let evidencePack else {
                    issues.append("groundedDataSummary missing evidence_pack")
                    break
                }
                let sourceType = evidencePack["source_type"] as? String
                if sourceType.map({ allowedEvidenceTypes.contains($0) }) != true {
                    issues.append("evidence_pack source_type expected \(allowedEvidenceTypes.sorted()), got \(sourceType ?? "nil")")
                }
                let sufficiency = evidencePack["sufficiency"] as? String
                if sufficiency == nil {
                    issues.append("evidence_pack missing sufficiency")
                }
                let items = evidencePack["items"] as? [[String: Any]] ?? []
                let itemCount = evidencePack["item_count"] as? Int ?? items.count
                if itemCount > 0 && items.isEmpty {
                    issues.append("evidence_pack item_count > 0 but items empty")
                }
            case .none:
                break
            }
        }

        return PhoneGroundPayloadValidation(issues: issues)
    }

    private func phoneGroundPayloadDictionary(from detail: String) -> [String: Any]? {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func synthesizedPhoneGroundMetadata(
        for contract: PhoneGroundToolContract,
        payload: [String: Any]
    ) -> [String: Any] {
        let evidenceType = contract.evidenceTypes.first?.rawValue ?? PhoneGroundEvidenceType.system.rawValue
        let status = payload["status"] as? String
            ?? ((payload["success"] as? Bool) == false ? "failed" : "succeeded")
        return [
            "version": "phoneground_v0",
            "evidence_type": evidenceType,
            "answer_contract": contract.answerContract.rawValue,
            "freshness": contract.freshness.rawValue,
            "privacy": phoneGroundPrivacy(for: contract),
            "status": status,
            "generated_by": "phoneground_normalizer"
        ]
    }

    private func phoneGroundPrivacy(for contract: PhoneGroundToolContract) -> String {
        if contract.evidenceTypes.contains(.web) {
            return "public_web"
        }
        if contract.evidenceTypes.contains(.health) {
            return "device_local"
        }
        return "local_or_user_scoped"
    }

    private func synthesizedDataEvidencePack(
        for contract: PhoneGroundToolContract,
        payload: [String: Any]
    ) -> [String: Any]? {
        let content = [
            payload["result"] as? String,
            payload["summary"] as? String,
            payload["message"] as? String,
            payload["error"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""

        guard !content.isEmpty else { return nil }

        let evidenceType = contract.evidenceTypes.first ?? .system
        let status = payload["status"] as? String
            ?? ((payload["success"] as? Bool) == false ? "failed" : "succeeded")
        return [
            "version": "phoneground_data_v0",
            "source_type": evidenceType.rawValue,
            "sufficiency": status,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "item_count": 1,
            "items": [
                [
                    "id": "normalized_summary",
                    "type": evidenceType.rawValue,
                    "title": tr("工具结果摘要", "Tool result summary"),
                    "content": content,
                    "confidence": "normalized_tool_result"
                ] as [String: Any]
            ],
            "phone_ground": synthesizedPhoneGroundMetadata(for: contract, payload: payload)
        ]
    }

    private func webAnswerContainsPlaceholder(_ answer: String) -> Bool {
        let lower = answer.lowercased()
        let fragments = [
            "[此处",
            "应根据工具返回",
            "待补充",
            "占位",
            "placeholder",
            "todo",
            "to be filled"
        ]
        return fragments.contains { lower.contains($0.lowercased()) }
    }

    private func bodyContainsInlineSourceMarker(_ body: String) -> Bool {
        body.range(of: #"(来源|Source)\s*[:：]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func markdownLinkCount(in text: String) -> Int {
        regexMatchCount(pattern: #"\[[^\]\n]{1,160}\]\(https?://[^\s)]+\)"#, in: text)
    }

    private func regexMatchCount(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        return regex.numberOfMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    private func webToolDetailHasUsableEvidence(_ detail: String) -> Bool {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if payload["answerability"] as? String == "direct" {
            return true
        }
        if payload["direct_evidence_sufficient"] as? Bool == true {
            return true
        }
        if let evidencePack = payload["evidence_pack"] as? [String: Any] {
            if evidencePack["sufficiency"] as? String == "sufficient" {
                return true
            }
            if let count = evidencePack["chunk_count"] as? Int, count >= 2 {
                return true
            }
            if let chunks = evidencePack["chunks"] as? [[String: Any]], chunks.count >= 2 {
                return true
            }
        }
        if payload["success"] as? Bool == true,
           payload["has_concrete_data"] as? Bool == true {
            let content = ((payload["content"] as? String) ?? (payload["result"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return content.count >= 80
        }
        return false
    }


    private func webAnswerLooksInsufficient(_ answer: String) -> Bool {
        let fragments = [
            "无法直接回答",
            "不能直接回答",
            "无法提供",
            "不能提供",
            "无法获取",
            "不能获取",
            "无法确定",
            "无法给出",
            "无法得出",
            "没有足够可",
            "没有提供",
            "没有包含",
            "没有找到",
            "没有返回明确",
            "没有返回足够",
            "页面中没有",
            "网页中没有",
            "不包含",
            "未包含",
            "未找到",
            "not enough",
            "insufficient",
            "not found",
            "cannot directly answer",
            "can't directly answer",
            "unable to provide",
            "cannot provide",
            "unable to get",
            "unable to find",
            "could not determine",
            "does not provide",
            "doesn't provide",
            "does not specify",
            "doesn't specify",
            "does not contain",
            "doesn't contain",
            "webpage fetch failed",
            "resource could not be loaded"
        ]
        let normalized = answer.lowercased()
        return fragments.contains { normalized.contains($0.lowercased()) }
    }

    private func webFetchResultNeedsSourceFallback(_ detail: String, userQuestion: String? = nil) -> Bool {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        guard (payload["success"] as? Bool) == true else {
            return true
        }
        if payload["looks_like_boilerplate"] as? Bool == true {
            return true
        }
        if payload["has_concrete_data"] as? Bool == false {
            return true
        }
        let content = ((payload["content"] as? String) ?? (payload["result"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 300 else {
            return true
        }
        let lower = content.lowercased()
        let failureMarkers = [
            "oops, something went wrong",
            "something went wrong",
            "access denied",
            "temporarily unavailable",
            "please try another search",
            "popular searches",
            "get 50% off",
            "free sign up",
            "sign in free sign up",
            "open in app",
            "enable javascript",
            "please enable javascript",
            "captcha",
            "not available right now",
            "advertisement advertisement advertisement",
            "loading score",
            "載入比分中",
            "加载比分中",
            "載入中",
            "加载中",
            "著作權所有",
            "服務條款",
            "服务条款",
            "會員中心",
            "会员中心"
        ]
        if failureMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let title = (payload["title"] as? String) ?? ""
        if let userQuestion,
           !fetchedPageLooksRelevant(title: title, content: content, userQuestion: userQuestion) {
            return true
        }

        return false
    }

    private func fallbackWebFetchFromRecentSearch(excluding attemptedURL: String?, userQuestion: String) async -> CanonicalToolResult? {
        let attemptedKey = normalizedSourceKey(attemptedURL ?? "")
        let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) ?? -1
        let currentTurnSlice = lastUserIdx >= 0 ? Array(messages.suffix(from: lastUserIdx)) : Array(messages)
        guard let searchResult = currentTurnSlice.last(where: {
            $0.role == .skillResult
                && $0.skillResultKind == .toolExecution
                && $0.skillName == "web-search"
        }) else {
            return nil
        }

        let candidateURLs = sourceURLs(fromToolResultDetail: searchResult.content)
            .filter { normalizedSourceKey($0) != attemptedKey }
            .prefix(6)

        for url in candidateURLs {
            do {
                let result = try await handleToolExecutionCanonical(
                    toolName: "web-fetch",
                    args: ["url": url, "max_characters": 6000]
                )
                if !webFetchResultNeedsSourceFallback(result.detail, userQuestion: userQuestion) {
                    log("[Agent] web-fetch fallback source succeeded: \(url)")
                    return result
                }
                log("[Agent] web-fetch fallback source still insufficient: \(url)")
            } catch {
                log("[Agent] web-fetch fallback source failed: \(url) \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func webSearchResultNeedsFetch(_ detail: String) -> Bool {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (payload["answerability"] as? String) == "needs_fetch"
    }

    private func automaticWebFetchFromSearchResult(_ searchDetail: String, userQuestion: String) async -> CanonicalToolResult? {
        let candidateURLs = sourceURLs(fromToolResultDetail: searchDetail).prefix(6)
        for url in candidateURLs {
            do {
                let result = try await handleToolExecutionCanonical(
                    toolName: "web-fetch",
                    args: ["url": url, "max_characters": 6000]
                )
                if !webFetchResultNeedsSourceFallback(result.detail, userQuestion: userQuestion) {
                    log("[Agent] web-search needs_fetch auto-fetched source: \(url)")
                    return result
                }
                log("[Agent] web-search needs_fetch auto-fetch source insufficient: \(url)")
            } catch {
                log("[Agent] web-search needs_fetch auto-fetch source failed: \(url) \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func retryWebAnswerWithFallbackSourceIfNeeded(
        answer: String,
        followUpToolName: String,
        toolResultDetail: String,
        userQuestion: String,
        images: [CIImage],
        msgIndex: Int
    ) async -> (answer: String, toolName: String, toolResultSummary: String, toolResultDetail: String)? {
        let validation = validateGroundedWebAnswer(
            appendSourceCitationIfNeeded(to: answer, toolName: followUpToolName, toolResultDetail: toolResultDetail),
            toolName: followUpToolName,
            toolResultDetail: toolResultDetail
        )
        guard followUpToolName == "web-fetch",
              (webAnswerLooksInsufficient(answer) || validation.shouldTryAlternativeFetch),
              let attemptedURL = sourceURLs(fromToolResultDetail: toolResultDetail).first,
              let fallbackResult = await fallbackWebFetchFromRecentSearch(
                excluding: attemptedURL,
                userQuestion: userQuestion
              ) else {
            return nil
        }

        let fallbackResultDetail = normalizePhoneGroundPayloadIfNeeded(
            toolName: "web-fetch",
            detail: fallbackResult.detail
        )
        messages.append(ChatMessage(
            role: .skillResult,
            content: fallbackResultDetail,
            skillName: "web-fetch",
            skillResultKind: .toolExecution
        ))
        messages[msgIndex].update(content: "▍")

        let retryPrompt = PromptBuilder.buildCompactToolAnswerPrompt(
            userQuestion: userQuestion,
            toolName: "web-fetch",
            toolResultSummary: fallbackResult.summary,
            currentImageCount: images.count,
            enableThinking: false
        )
        guard let retryText = await streamLLM(prompt: retryPrompt, msgIndex: msgIndex, images: images) else {
            return nil
        }

        let cleaned = cleanOutput(retryText)
        guard !cleaned.isEmpty,
              !looksLikeStructuredIntermediateOutput(cleaned),
              !looksLikePromptEcho(cleaned) else {
            return nil
        }

        log("[Agent] web-fetch answer insufficient; retried with fallback source")
        return (cleaned, "web-fetch", fallbackResult.summary, fallbackResultDetail)
    }

    private func normalizedSourceKey(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return rawURL.lowercased()
        }
        components.scheme = "https"
        components.query = nil
        components.fragment = nil
        return (components.url?.absoluteString ?? rawURL).lowercased()
    }

    private func fetchedPageLooksRelevant(title: String, content: String, userQuestion: String) -> Bool {
        let concepts = significantQuestionConcepts(userQuestion)
        guard !concepts.isEmpty else { return true }

        let haystack = content.lowercased()
        var totalOccurrences = 0
        let matchCount = concepts.reduce(into: 0) { count, alternatives in
            var conceptOccurrences = 0
            for term in alternatives {
                let needle = term.lowercased()
                conceptOccurrences += haystack.components(separatedBy: needle).count - 1
            }
            if conceptOccurrences > 0 {
                count += 1
                totalOccurrences += conceptOccurrences
            }
        }
        let requiredMatches = concepts.count >= 2 ? 2 : 1
        return matchCount >= requiredMatches && totalOccurrences >= requiredMatches + 1
    }

    private func significantQuestionConcepts(_ question: String) -> [[String]] {
        var normalized = question.lowercased()
        let stopPhrases = [
            "帮我", "请问", "查一下", "搜一下", "搜索", "查询", "一下",
            "今天", "今日", "现在", "当前", "最近", "最新", "多少", "如何", "怎么样", "怎样",
            "的是", "的吗", "是吗", "是", "吗", "呢", "么",
            "the", "and", "for", "with", "to", "from", "what", "whats", "what's", "today", "current", "latest",
            "search", "look", "lookup", "find", "are", "is", "was", "were", "about", "please"
        ]
        for phrase in stopPhrases {
            normalized = normalized.replacingOccurrences(of: phrase, with: " ")
        }

        var concepts: [[String]] = []

        let cjkPattern = #"[\p{Han}]{2,}"#
        if let regex = try? NSRegularExpression(pattern: cjkPattern) {
            let nsRange = NSRange(normalized.startIndex..., in: normalized)
            for match in regex.matches(in: normalized, range: nsRange) {
                guard let range = Range(match.range, in: normalized) else { continue }
                let chunk = String(normalized[range])
                var alternatives = [chunk]
                let chars = Array(chunk)
                if chars.count > 2 {
                    alternatives.append(String(chars.prefix(2)))
                    alternatives.append(String(chars.suffix(2)))
                    for index in 0..<(chars.count - 1) {
                        alternatives.append(String(chars[index...(index + 1)]))
                    }
                }
                concepts.append(uniqueTerms(alternatives))
            }
        }

        let latinTokens = normalized
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
            .filter { !isAllHan($0) }
        concepts.append(contentsOf: latinTokens.map { [$0] })

        var seen = Set<String>()
        return concepts.compactMap { alternatives in
            let cleaned = uniqueTerms(alternatives).filter { $0.count >= 2 }
            guard !cleaned.isEmpty else { return nil }
            let key = cleaned.joined(separator: "|")
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return cleaned
        }
    }

    private func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { term in
            guard !seen.contains(term) else { return false }
            seen.insert(term)
            return true
        }
    }

    private func isAllHan(_ text: String) -> Bool {
        text.range(of: #"^[\p{Han}]+$"#, options: .regularExpression) != nil
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
            finishTurn()
            return
        }

        // 重复检测 — 同名 tool 在【当前 user turn】内已跑过 ≥1 次 → 跳过本次执行,
        // 让模型继续推进. 只算"距离最后一条 user message 之间"的 skillResult,
        // 跨 turn 不算 (e.g. turn 1 fired reminders, turn 2 又 fire 是合法补参, 不是循环).
        let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) ?? -1
        let currentTurnSlice = lastUserIdx >= 0 ? Array(messages.suffix(from: lastUserIdx)) : Array(messages)
        // 只数「真实工具执行」(toolExecution) 的结果 —— load_skill 注入的说明书 (skillInstructions)
        // 和 content skill 生成文本 (generatedContent) 不算"工具已跑过"。否则 skill-id == tool-name
        // (如 web-search) 时, "已加载说明书" 会被误判成 "工具已执行"、跳过真正的搜索 → 模型瞎编占位符。
        let recentResults = currentTurnSlice.filter {
            $0.role == .skillResult && $0.skillResultKind == .toolExecution
        }
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
                    finishTurn()
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
                    finishTurn()
                }
                return
            }
        }

        guard let parsedCall = parseToolCall(fullText) else {
            let cleaned = cleanOutput(fullText)
            if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastAssistant].update(content: cleaned.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : cleaned)
            }
            finishTurn()
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
            messages.append(ChatMessage(role: .skillResult, content: resultText, skillName: "list_skills", skillResultKind: .toolExecution))

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
                finishTurn()
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
                finishTurn()
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
                messages.append(ChatMessage(role: .skillResult, content: instructions, skillName: skillName, skillResultKind: .skillInstructions))
                allInstructions += instructions + "\n\n"
                loadedSkillIds.append(skillName)
            }

            guard !allInstructions.isEmpty else {
                finishTurn()
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
                finishTurn()
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
                finishTurn()
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
                        finishTurn()
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
                        finishTurn()
                    }
                } else {
                    messages[followUpIndex].update(content: cleaned)
                    markSkillsDone(loadedDisplayNames)
                    finishTurn()
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
            finishTurn()
            return
        }

        let enabledIds = Set(skillEntries.filter(\.isEnabled).map(\.id))
        guard enabledIds.contains(ownerSkillId!) else {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: tr(
                "⚠️ Skill \(displayName) 未启用",
                "⚠️ Skill \(displayName) is not enabled"
            )))
            finishTurn()
            return
        }

        messages[cardIndex].update(role: .system, content: "executing:\(call.name)", skillName: displayName)

        do {
            var executionArguments = call.arguments
            if canonicalToolName(call.name, arguments: call.arguments) == "web-search",
               (executionArguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                executionArguments["question"] = userQuestion
            }
            if canonicalToolName(call.name, arguments: call.arguments) == "web-search",
               executionArguments["planned_queries"] == nil {
                let initialQuery = (executionArguments["query"] as? String) ?? userQuestion
                let plannedQueries = await modelPlannedWebQueries(
                    userQuestion: userQuestion,
                    initialQuery: initialQuery,
                    images: images
                )
                if !plannedQueries.isEmpty {
                    executionArguments["planned_queries"] = plannedQueries
                }
            }

            var canonicalResult: CanonicalToolResult
            var toolResultDetail: String
            if HotfixFeatureFlags.useHotfixPromptPipeline && HotfixFeatureFlags.enableCanonicalToolResult {
                canonicalResult = try await handleToolExecutionCanonical(toolName: call.name, args: executionArguments)
                toolResultDetail = canonicalResult.detail
            } else {
                let toolResult = try await handleToolExecution(toolName: call.name, args: executionArguments)
                canonicalResult = canonicalToolResult(toolName: call.name, toolResult: toolResult)
                toolResultDetail = toolResult
            }

            if call.name == "web-fetch",
               webFetchResultNeedsSourceFallback(toolResultDetail, userQuestion: userQuestion),
               let fallbackResult = await fallbackWebFetchFromRecentSearch(excluding: executionArguments["url"] as? String, userQuestion: userQuestion) {
                canonicalResult = fallbackResult
                toolResultDetail = fallbackResult.detail
            }

            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            toolResultDetail = normalizePhoneGroundPayloadIfNeeded(toolName: call.name, detail: toolResultDetail)
            messages.append(ChatMessage(role: .skillResult, content: toolResultDetail, skillName: call.name, skillResultKind: .toolExecution))
            log("[Agent] Tool \(call.name) round \(round) done")

            if !canonicalResult.success {
                messages.append(ChatMessage(role: .assistant, content: canonicalResult.summary))
                finishTurn()
                return
            }

            var followUpToolName = call.name
            if call.name == "web-search", webSearchResultNeedsFetch(toolResultDetail) {
                if let fetchedResult = await automaticWebFetchFromSearchResult(toolResultDetail, userQuestion: userQuestion) {
                    canonicalResult = fetchedResult
                    toolResultDetail = fetchedResult.detail
                    followUpToolName = "web-fetch"
                    toolResultDetail = normalizePhoneGroundPayloadIfNeeded(toolName: followUpToolName, detail: toolResultDetail)
                    messages.append(ChatMessage(role: .skillResult, content: toolResultDetail, skillName: followUpToolName, skillResultKind: .toolExecution))
                } else if let replannedSearchResult = await retryWebSearchWithReplannedQueriesIfNeeded(
                    searchDetail: toolResultDetail,
                    userQuestion: userQuestion,
                    images: images
                ) {
                    canonicalResult = replannedSearchResult
                    toolResultDetail = replannedSearchResult.detail
                    followUpToolName = "web-search"
                    toolResultDetail = normalizePhoneGroundPayloadIfNeeded(toolName: followUpToolName, detail: toolResultDetail)
                    messages.append(ChatMessage(role: .skillResult, content: toolResultDetail, skillName: followUpToolName, skillResultKind: .toolExecution))

                    if webSearchResultNeedsFetch(toolResultDetail),
                       let fetchedResult = await automaticWebFetchFromSearchResult(toolResultDetail, userQuestion: userQuestion) {
                        canonicalResult = fetchedResult
                        toolResultDetail = fetchedResult.detail
                        followUpToolName = "web-fetch"
                        toolResultDetail = normalizePhoneGroundPayloadIfNeeded(toolName: followUpToolName, detail: toolResultDetail)
                        messages.append(ChatMessage(role: .skillResult, content: toolResultDetail, skillName: followUpToolName, skillResultKind: .toolExecution))
                    }
                }
            }

            if toolRegistry.shouldSkipFollowUp(for: followUpToolName) {
                messages.append(ChatMessage(role: .assistant, content: canonicalResult.summary))
                finishTurn()
                return
            }

            // F3: R2 prompt = R1 prompt + R1 output + tool_result message.
            // 物理上是 R1 conversation 的延伸 → KV cache 自然命中 R1 全部 token.
            let followUpPrompt = PromptBuilder.appendToolResult(
                toR1Prompt: prompt,
                r1Output: fullText,
                toolName: followUpToolName,
                toolResultSummary: canonicalResult.summary
            )

            let selectedFollowUpPrompt = (effectiveEnableThinking || shouldUseCompactToolFollowUp(followUpPrompt, toolName: followUpToolName))
                ? PromptBuilder.buildCompactToolAnswerPrompt(
                    userQuestion: userQuestion,
                    toolName: followUpToolName,
                    toolResultSummary: canonicalResult.summary,
                    currentImageCount: images.count,
                    // 工具结果后的 R2/R3 是“基于已得证据输出最终答案/继续必要工具”的阶段。
                    // Gemma 4 在这里重新开启 thinking 时容易输出未闭合 thought 通道, UI 会只显示思考卡片而没有最终答案。
                    // 用户选择的 Think 仍作用于 R1 工具决策; 结果汇总阶段保持普通答案, 确保结果可见。
                    enableThinking: false
                )
                : followUpPrompt

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: selectedFollowUpPrompt, msgIndex: followUpIndex, images: images) else {
                messages[followUpIndex].update(role: .assistant, content: fallbackReplyForEmptyToolFollowUp(
                    toolName: followUpToolName,
                    toolResultSummary: canonicalResult.summary,
                    toolResultDetail: toolResultDetail
                ))
                finishTurn()
                return
            }

            if !parseAllToolCalls(nextText).isEmpty {
                log("[Agent] 检测到第 \(round + 1) 轮工具调用")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: selectedFollowUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, images: images, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                if cleaned.isEmpty
                    || looksLikeStructuredIntermediateOutput(cleaned)
                    || looksLikePromptEcho(cleaned) {
                    messages[followUpIndex].update(content: fallbackReplyForEmptyToolFollowUp(
                        toolName: followUpToolName,
                        toolResultSummary: canonicalResult.summary,
                        toolResultDetail: toolResultDetail
                    ))
                } else {
                    let finalAnswer: String
                    let finalToolName: String
                    let finalToolResultSummary: String
                    let finalToolResultDetail: String
                    if let retry = await retryWebAnswerWithFallbackSourceIfNeeded(
                        answer: cleaned,
                        followUpToolName: followUpToolName,
                        toolResultDetail: toolResultDetail,
                        userQuestion: userQuestion,
                        images: images,
                        msgIndex: followUpIndex
                    ) {
                        finalAnswer = retry.answer
                        finalToolName = retry.toolName
                        finalToolResultSummary = retry.toolResultSummary
                        finalToolResultDetail = retry.toolResultDetail
                    } else {
                        finalAnswer = cleaned
                        finalToolName = followUpToolName
                        finalToolResultSummary = canonicalResult.summary
                        finalToolResultDetail = toolResultDetail
                    }
                    let finalizedAnswer = await finalizeWebAnswer(
                        finalAnswer,
                        toolName: finalToolName,
                        toolResultSummary: finalToolResultSummary,
                        toolResultDetail: finalToolResultDetail,
                        userQuestion: userQuestion,
                        images: images,
                        msgIndex: followUpIndex
                    )
                    messages[followUpIndex].update(content: finalizedAnswer)
                }
                finishTurn()
            }
        } catch {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .system, content: tr(
                "这项操作没有完成：\(error.localizedDescription)",
                "This action could not be completed: \(error.localizedDescription)"
            )))
            finishTurn()
        }
    }
}
