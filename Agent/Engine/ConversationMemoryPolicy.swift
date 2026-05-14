import Foundation

// MARK: - Prompt Token Estimator
//
// 中英文混合 prompt 的 token 估算。基于 SentencePiece (Gemma 4 用) 在中英文
// 混合内容上的统计:
//   - CJK 字符: ~1.5 chars/token (汉字单字常占 1-2 token)
//   - 拉丁/数字/标点: ~4.0 chars/token (BPE 合并后的常见词)
//
// 原始 plan §九 Phase 3 提出"中文 ~1.5 字/token"。这里取折中:
// 把 prompt 按 unicode scalar 类别加权累加。误差 ±15%,够 context budget 预算用。

enum PromptTokenEstimator {

    /// 估算 prompt 的 token 数。最小返回 1。
    static func estimate(_ prompt: String) -> Int {
        guard !prompt.isEmpty else { return 1 }
        var cjkCount = 0
        var otherCount = 0
        for scalar in prompt.unicodeScalars {
            if isCJK(scalar) {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        let cjkTokens = Double(cjkCount) / 1.5
        let otherTokens = Double(otherCount) / 4.0
        return max(1, Int((cjkTokens + otherTokens).rounded(.up)))
    }

    /// CJK 范围: 主要汉字 + 假名 + 韩文 + 全角标点。
    /// 这些字符在 SentencePiece BPE 中通常 1-2 token,远低于拉丁文的 4 字/token。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3000...0x303F).contains(v)   // CJK Symbols and Punctuation
            || (0x3040...0x309F).contains(v)   // Hiragana
            || (0x30A0...0x30FF).contains(v)   // Katakana
            || (0x3400...0x4DBF).contains(v)   // CJK Unified Ideographs Ext A
            || (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs (主)
            || (0xAC00...0xD7AF).contains(v)   // Hangul Syllables
            || (0xF900...0xFAFF).contains(v)   // CJK Compatibility Ideographs
            || (0xFF00...0xFFEF).contains(v)   // Halfwidth and Fullwidth Forms
            || (0x20000...0x2A6DF).contains(v) // CJK Unified Ideographs Ext B
    }
}

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
