import Foundation

// MARK: - Prompt Pipeline Helpers
//
// 从 AgentEngine 提取的 prompt 构建辅助方法:
// - PromptShape / SessionGroup / ReuseDecision 决策
// - PromptPlan 构建
// - 上下文预算 (context budget) 检查
// - KV session 转换
// - 推理诊断观测 (HotfixTurnObservation)

extension AgentEngine {

    var selectedModelCapabilities: ModelCapabilities {
        catalog.selectedModel.capabilities
    }

    func promptShape(
        requiresMultimodal: Bool,
        shouldUseFullAgentPrompt: Bool,
        canUseDelta: Bool
    ) -> PromptShape {
        if requiresMultimodal {
            return .multimodal
        }
        if config.enableThinking {
            return .thinking
        }
        if shouldUseFullAgentPrompt {
            return .agentFull
        }
        return canUseDelta ? .lightDelta : .lightFull
    }

    func sessionGroup(for shape: PromptShape) -> SessionGroup {
        switch shape {
        case .multimodal:
            return .multimodal
        case .live:
            return .live
        case .lightFull, .lightDelta, .agentFull, .toolFollowup, .thinking:
            return .text
        }
    }

    func reuseDecision(
        for nextShape: PromptShape,
        nextGroup: SessionGroup
    ) -> ReuseDecision {
        guard let previousShape = previousPromptShape,
              let previousSessionGroup else {
            return .reset(.firstTurn)
        }

        guard previousSessionGroup == nextGroup else {
            switch nextGroup {
            case .text:
                return .reset(.enterText)
            case .multimodal:
                return .reset(.enterMultimodal)
            case .live:
                return .reset(.enterLive)
            }
        }

        switch (previousShape, nextShape) {
        case (.lightFull, .lightDelta),
             (.lightDelta, .lightDelta),
             (.toolFollowup, .toolFollowup),
             (.thinking, .thinking):
            return .reuse
        case (.agentFull, .toolFollowup):
            return .reuse
        case (.lightFull, .lightFull),
             (.lightDelta, .lightFull):
            return .reset(.systemChanged)
        case (.agentFull, .agentFull):
            return .reset(.toolSchemaChanged)
        case (.thinking, .lightFull),
             (.thinking, .lightDelta),
             (.lightFull, .thinking),
             (.lightDelta, .thinking):
            return .reset(.thinkingToggle)
        default:
            return .reset(.shapeChanged)
        }
    }

    func makePromptPlan(
        prompt: String,
        shape: PromptShape,
        history: [ChatMessage],
        historyDepth: Int
    ) -> PromptPlan {
        let sessionGroup = sessionGroup(for: shape)
        let budgetDecision = activeContextBudgetPlanner.makeDecision(
            prompt: prompt,
            capabilities: selectedModelCapabilities,
            history: history,
            historyDepth: historyDepth,
            maxOutputTokens: inference.maxOutputTokens
        )
        let reuseDecision = reuseDecision(for: shape, nextGroup: sessionGroup)
        return PromptPlan(
            shape: shape,
            sessionGroup: sessionGroup,
            prompt: prompt,
            budgetDecision: budgetDecision,
            reuseDecision: reuseDecision
        )
    }

    var activeContextBudgetPlanner: ContextBudgetPlanner {
        if HotfixFeatureFlags.useHotfixPromptPipeline && HotfixFeatureFlags.enablePreflightBudget {
            return hotfixContextBudgetPlanner
        }
        return legacyContextBudgetPlanner
    }

    func exceedsSafeContextBudget(_ decision: BudgetDecision) -> Bool {
        decision.estimatedPromptTokens + decision.reservedOutputTokens
            > selectedModelCapabilities.safeContextBudgetTokens
    }

    func buildTextPromptBundle(
        priorHistory: [ChatMessage],
        normalizedText: String,
        shouldUsePlanner: Bool,
        shouldUseFullAgentPrompt: Bool,
        includeTimeAnchor: Bool,
        includeImageHistoryMarkers: Bool,
        imageFollowUpBridgeSummary: String?,
        activeSkillInfos: [SkillInfo],
        matchedSkillIdsForTurn: [String],
        preloadedSkills: [PromptBuilder.PreloadedSkill],
        currentUserMessage: ChatMessage
    ) -> (
        lightPrompt: String,
        agentPrompt: String?,
        plannerInputPrompt: String,
        streamingPrompt: String,
        canUseDelta: Bool,
        streamingPlanningHistory: [ChatMessage]
    ) {
        let lightHistory = shouldUsePlanner ? [] : priorHistory
        let lightPrompt = PromptBuilder.buildLightweightTextPrompt(
            userMessage: normalizedText,
            history: lightHistory,
            systemPrompt: config.systemPrompt,
            enableThinking: config.enableThinking,
            historyDepth: lightHistory.count,
            includeImageHistoryMarkers: includeImageHistoryMarkers,
            imageFollowUpBridgeSummary: imageFollowUpBridgeSummary
        )
        let agentPrompt: String? = shouldUseFullAgentPrompt ? PromptBuilder.build(
            userMessage: normalizedText,
            currentImageCount: 0,
            tools: activeSkillInfos,
            includeTimeAnchor: includeTimeAnchor,
            includeImageHistoryMarkers: includeImageHistoryMarkers,
            imageFollowUpBridgeSummary: imageFollowUpBridgeSummary,
            history: priorHistory,
            systemPrompt: config.systemPrompt,
            enableThinking: config.enableThinking,
            historyDepth: priorHistory.count,
            showListSkillsHint: matchedSkillIdsForTurn.isEmpty,
            preloadedSkills: preloadedSkills
        ) : nil

        let canUseDelta = inference.kvSessionActive
            && inference.sessionHasContext
            && agentPrompt == nil

        let streamingPrompt: String
        if canUseDelta {
            streamingPrompt = PromptBuilder.buildDeltaTurnPrompt(
                userMessage: normalizedText,
                currentImageCount: 0,
                enableThinking: config.enableThinking
            )
        } else {
            streamingPrompt = agentPrompt ?? lightPrompt
        }

        let streamingPriorHistory = agentPrompt != nil ? priorHistory : lightHistory
        return (
            lightPrompt: lightPrompt,
            agentPrompt: agentPrompt,
            plannerInputPrompt: lightPrompt,
            streamingPrompt: streamingPrompt,
            canUseDelta: canUseDelta,
            streamingPlanningHistory: ConversationMemoryPolicy.planningHistory(
                from: streamingPriorHistory,
                currentUser: currentUserMessage
            )
        )
    }

    // MARK: - Observation / Diagnostics

    func kvPrefillTokensForCurrentTurn() -> Int {
        // 协议默认实现返回 0 (无 KV 能力的后端); LiteRTBackend 覆写成真实值。
        inference.lastKVPrefillTokens
    }

    func recordCompletedObservation(
        plan: PromptPlan,
        advancePromptPipelineState: Bool = true,
        preflightHardReject: Bool = false,
        tokenCapHit: Bool = false,
        memoryFloorHit: Bool = false
    ) {
        let observation = HotfixTurnObservation(
            prompt_shape: plan.shape.rawValue,
            session_group: plan.sessionGroup.rawValue,
            session_reset_reason: plan.sessionResetReason.rawValue,
            estimated_prompt_tokens: plan.budgetDecision.estimatedPromptTokens,
            reserved_output_tokens: plan.budgetDecision.reservedOutputTokens,
            history_messages_included: plan.budgetDecision.historyMessagesIncluded,
            history_chars_included: plan.budgetDecision.historyCharsIncluded,
            kv_prefill_tokens: kvPrefillTokensForCurrentTurn(),
            preflight_hard_reject: preflightHardReject,
            timestamp_ms: Int64(Date().timeIntervalSince1970 * 1000)
        )
        promptObservationBuffer.append(observation)
        if advancePromptPipelineState {
            previousPromptShape = plan.shape
            previousSessionGroup = plan.sessionGroup
        }

        if tokenCapHit
            || memoryFloorHit
            || plan.sessionResetReason != .normalContinuation
            || preflightHardReject {
            for item in promptObservationBuffer.recent(3) {
                log("[Hotfix] \(item.jsonLine())")
            }
        }
    }

    func classifyTokenCapHit(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("max number of tokens reached")
    }

    func classifyMemoryFloorHit(_ error: Error) -> Bool {
        if let backendError = error as? ModelBackendError,
           case .memoryRisk = backendError {
            return true
        }

        let message = error.localizedDescription
        return message.contains("当前剩余内存")
            || message.localizedCaseInsensitiveContains("headroom")
            || message.localizedCaseInsensitiveContains("memory risk")
    }

    func resetPromptPipelineState() {
        previousPromptShape = nil
        previousSessionGroup = nil
    }

    func prepareSessionGroupTransitionIfNeeded(for plan: PromptPlan) async {
        guard HotfixFeatureFlags.useHotfixPromptPipeline,
              HotfixFeatureFlags.enableMultimodalSessionGroup else {
            return
        }
        await inference.prepareForSessionGroupTransition(
            from: previousSessionGroup,
            to: plan.sessionGroup
        )
    }
}
