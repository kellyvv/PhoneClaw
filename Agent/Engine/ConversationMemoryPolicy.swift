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
        guard !priorHistory.isEmpty else { return nil }

        if let skillResultIndex = priorHistory.firstIndex(where: { $0.role == .skillResult }) {
            var trimmed = priorHistory
            let message = trimmed[skillResultIndex]
            if let toolName = message.skillName {
                let summary = canonicalToolResult(toolName: toolName, toolResult: message.content).summary
                let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedDetail = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedSummary.isEmpty && normalizedSummary != normalizedDetail {
                    trimmed[skillResultIndex].update(content: normalizedSummary)
                    return trimmed
                }
            }
            trimmed.remove(at: skillResultIndex)
            return trimmed
        }

        let protectedAssistantIndex = priorHistory.lastIndex(where: { $0.role == .assistant })

        if let assistantIndex = priorHistory.indices.first(where: {
            priorHistory[$0].role == .assistant
                && $0 != protectedAssistantIndex
                && priorHistory[$0].content.count > 240
        }) {
            var trimmed = priorHistory
            trimmed[assistantIndex].update(
                content: truncatedAssistantContent(trimmed[assistantIndex].content)
            )
            return trimmed
        }

        if let assistantIndex = priorHistory.indices.first(where: {
            priorHistory[$0].role == .assistant && $0 != protectedAssistantIndex
        }) {
            var trimmed = priorHistory
            trimmed.remove(at: assistantIndex)
            return trimmed
        }

        if let dropRange = oldestDroppableTurnRange(
            in: priorHistory,
            protectedAssistantIndex: protectedAssistantIndex
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

    private static func oldestDroppableTurnRange(
        in priorHistory: [ChatMessage],
        protectedAssistantIndex: Int?
    ) -> Range<Int>? {
        let userIndices = priorHistory.indices.filter { priorHistory[$0].role == .user }
        guard !userIndices.isEmpty else { return nil }

        let protectedIndex = protectedAssistantIndex ?? Int.max
        for (offset, userIndex) in userIndices.enumerated() {
            let nextUserIndex = offset + 1 < userIndices.count
                ? userIndices[offset + 1]
                : priorHistory.count
            if nextUserIndex <= protectedIndex {
                return userIndex..<nextUserIndex
            }
        }

        return nil
    }
}
