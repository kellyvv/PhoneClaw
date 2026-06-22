import Foundation

// MARK: - Context Budget Planner
//
// 上下文窗口预算规划: 根据历史消息 + 当前 prompt 估算 token 占用,
// 决定保留多少历史和预留多少输出空间。
// 两种策略: Legacy (旧版) 和 Hotfix (新版)，由 HotfixFeatureFlags 控制。

protocol ContextBudgetPlanner {
    func makeDecision(
        prompt: String,
        capabilities: ModelCapabilities,
        history: [ChatMessage],
        historyDepth: Int,
        maxOutputTokens: Int
    ) -> BudgetDecision
}

struct LegacyBudgetPlanner: ContextBudgetPlanner {
    func makeDecision(
        prompt: String,
        capabilities: ModelCapabilities,
        history: [ChatMessage],
        historyDepth: Int,
        maxOutputTokens: Int
    ) -> BudgetDecision {
        let stats = ConversationMemoryPolicy.legacyHistoryStats(
            from: history,
            historyDepth: historyDepth
        )
        let estimatedPromptTokens = PromptTokenEstimator.estimate(prompt)
        let reservedOutputTokens = min(maxOutputTokens, capabilities.defaultReservedOutputTokens)
        return BudgetDecision(
            estimatedPromptTokens: estimatedPromptTokens,
            reservedOutputTokens: reservedOutputTokens,
            historyMessagesIncluded: stats.messageCount,
            historyCharsIncluded: stats.characterCount
        )
    }
}

struct HotfixBudgetPlanner: ContextBudgetPlanner {
    func makeDecision(
        prompt: String,
        capabilities: ModelCapabilities,
        history: [ChatMessage],
        historyDepth: Int,
        maxOutputTokens: Int
    ) -> BudgetDecision {
        let stats = ConversationMemoryPolicy.hotfixHistoryStats(
            fromPlanningHistory: history,
            historyDepth: historyDepth
        )
        let estimatedPromptTokens = PromptTokenEstimator.estimate(prompt)
        let reservedOutputTokens = min(maxOutputTokens, capabilities.defaultReservedOutputTokens)
        return BudgetDecision(
            estimatedPromptTokens: estimatedPromptTokens,
            reservedOutputTokens: reservedOutputTokens,
            historyMessagesIncluded: stats.messageCount,
            historyCharsIncluded: stats.characterCount
        )
    }
}

// MARK: - Conversation Memory Policy
//
// 会话历史记忆策略: 控制 KV cache 友好的历史截断、压缩、丢弃逻辑。
// 纯静态方法，不持有状态。

struct ConversationMemoryPolicy {
    struct LegacyHistoryStats: Equatable {
        let messageCount: Int
        let characterCount: Int
    }

    static func legacyHistorySlice(
        from history: [ChatMessage],
        historyDepth: Int
    ) -> ArraySlice<ChatMessage> {
        history.suffix(historyDepth)
    }

    static func legacyHistoryStats(
        from history: [ChatMessage],
        historyDepth: Int
    ) -> LegacyHistoryStats {
        let recentHistory = legacyHistorySlice(from: history, historyDepth: historyDepth)
        let lastUserID = recentHistory.last(where: { $0.role == .user })?.id

        var messageCount = 0
        var characterCount = 0

        for message in recentHistory {
            if message.role == .user, message.id == lastUserID {
                continue
            }
            messageCount += 1
            characterCount += message.content.count
        }

        return LegacyHistoryStats(
            messageCount: messageCount,
            characterCount: characterCount
        )
    }

    static func planningHistory(
        from priorHistory: [ChatMessage],
        currentUser: ChatMessage
    ) -> [ChatMessage] {
        priorHistory + [currentUser]
    }

    static func hotfixHistoryStats(
        fromPlanningHistory history: [ChatMessage],
        historyDepth: Int
    ) -> LegacyHistoryStats {
        let recentHistory = history.suffix(historyDepth)
        let effectiveHistory: ArraySlice<ChatMessage>
        if recentHistory.last?.role == .user {
            effectiveHistory = recentHistory.dropLast()
        } else {
            effectiveHistory = recentHistory
        }

        return LegacyHistoryStats(
            messageCount: effectiveHistory.count,
            characterCount: effectiveHistory.reduce(0) { $0 + $1.content.count }
        )
    }

    static func nextTrimmedPriorHistory(from priorHistory: [ChatMessage]) -> [ChatMessage]? {
        nextTrimmedPriorHistory(from: priorHistory, historyPolicyForSkillOrTool: nil)
    }

    static func nextTrimmedPriorHistory(
        from priorHistory: [ChatMessage],
        historyPolicyForSkillOrTool: ((String) -> SkillHistoryPolicy?)?
    ) -> [ChatMessage]? {
        guard !priorHistory.isEmpty else { return nil }
        let protectedIndices = pendingClarificationProtectedIndices(
            in: priorHistory,
            historyPolicyForSkillOrTool: historyPolicyForSkillOrTool
        )

        for skillResultIndex in priorHistory.indices where priorHistory[skillResultIndex].role == .skillResult {
            guard !protectedIndices.contains(skillResultIndex) else { continue }
            var trimmed = priorHistory
            let message = trimmed[skillResultIndex]
            let policy = message.skillName.flatMap { historyPolicyForSkillOrTool?($0) }
            if message.skillResultKind == .toolExecution, let toolName = message.skillName {
                let summary = canonicalToolResult(toolName: toolName, toolResult: message.content).summary
                let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedDetail = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if policy?.summarizeOldEvidence != false,
                   !normalizedSummary.isEmpty,
                   normalizedSummary != normalizedDetail {
                    trimmed[skillResultIndex].update(content: normalizedSummary)
                    return trimmed
                }
            }
            if policy?.dropCompletedToolCalls != false {
                trimmed.remove(at: skillResultIndex)
                return trimmed
            }
        }

        let protectedAssistantIndex = priorHistory.lastIndex(where: { $0.role == .assistant })
        var allProtectedIndices = protectedIndices
        if let protectedAssistantIndex {
            allProtectedIndices.insert(protectedAssistantIndex)
        }

        if let assistantIndex = priorHistory.indices.first(where: {
            priorHistory[$0].role == .assistant
                && !allProtectedIndices.contains($0)
                && priorHistory[$0].content.count > 240
        }) {
            var trimmed = priorHistory
            trimmed[assistantIndex].update(
                content: truncatedAssistantContent(trimmed[assistantIndex].content)
            )
            return trimmed
        }

        if let assistantIndex = priorHistory.indices.first(where: {
            priorHistory[$0].role == .assistant && !allProtectedIndices.contains($0)
        }) {
            var trimmed = priorHistory
            trimmed.remove(at: assistantIndex)
            return trimmed
        }

        if let dropRange = oldestDroppableTurnRange(
            in: priorHistory,
            protectedIndices: allProtectedIndices
        ) {
            var trimmed = priorHistory
            trimmed.removeSubrange(dropRange)
            return trimmed
        }

        return nil
    }

    private static func truncatedAssistantContent(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else { return trimmed }
        let prefix = String(trimmed.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }

    private static func pendingClarificationProtectedIndices(
        in priorHistory: [ChatMessage],
        historyPolicyForSkillOrTool: ((String) -> SkillHistoryPolicy?)?
    ) -> Set<Int> {
        guard let historyPolicyForSkillOrTool,
              let assistantIndex = priorHistory.indices.last,
              priorHistory[assistantIndex].role == .assistant,
              looksLikePendingClarification(priorHistory[assistantIndex].content) else {
            return []
        }

        let policy: SkillHistoryPolicy? = priorHistory[..<assistantIndex].reversed().compactMap { message in
            guard let name = message.skillName,
                  let policy = historyPolicyForSkillOrTool(name) else { return nil }
            return policy
        }.first
        guard policy?.preservePendingClarification == true else { return [] }

        let turnStart = priorHistory[..<assistantIndex].lastIndex(where: { $0.role == .user })
            ?? assistantIndex
        return Set(turnStart...assistantIndex)
    }

    private static func looksLikePendingClarification(_ content: String) -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.contains("?") || text.contains("？") || text.contains("吗") || text.contains("呢") {
            return true
        }

        let lowercased = text.lowercased()
        let markers = [
            "请提供", "请补充", "请告诉", "需要提供", "需要补充",
            "什么时候", "什么时间", "哪一个", "哪个", "哪位",
            "电话号", "电话号码", "手机号", "主题是什么", "标题是什么",
            "要安排什么", "提醒您做什么",
            "please provide", "please specify", "which one", "which contact",
            "when should", "what time", "phone number", "what would you like",
            "what's the topic", "what is the topic",
            "教えて", "指定", "どれ", "いつ", "何時", "電話", "件名"
        ]
        return markers.contains { lowercased.contains($0.lowercased()) }
    }

    private static func oldestDroppableTurnRange(
        in priorHistory: [ChatMessage],
        protectedIndices: Set<Int>
    ) -> Range<Int>? {
        let userIndices = priorHistory.indices.filter { priorHistory[$0].role == .user }
        guard !userIndices.isEmpty else { return nil }

        for (offset, userIndex) in userIndices.enumerated() {
            let nextUserIndex = offset + 1 < userIndices.count
                ? userIndices[offset + 1]
                : priorHistory.count
            let range = userIndex..<nextUserIndex
            guard !range.contains(where: { protectedIndices.contains($0) }) else { continue }
            return range
        }

        return nil
    }
}
