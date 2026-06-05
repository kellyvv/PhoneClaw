import CryptoKit
import Foundation

private struct InferenceSamplingSnapshot {
    let topK: Int
    let topP: Float
    let temperature: Float
    let maxOutputTokens: Int
}

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

    var effectiveEnableThinking: Bool {
        config.enableThinking && selectedModelCapabilities.supportsThinking
    }

    func promptShape(
        requiresMultimodal: Bool,
        shouldUseFullAgentPrompt: Bool,
        canUseDelta: Bool
    ) -> PromptShape {
        if requiresMultimodal {
            return .multimodal
        }
        if effectiveEnableThinking {
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

    func logPromptDiagnostics(label: String, prompt: String) {
        let markers = [
            "<|turn>system",
            "<|turn>user",
            "<|turn>model",
            "<turn|>",
            "<tool_call>",
            "<|tool_call>",
            "<tool|>",
            "<|tool>",
            "<|think|>",
            "<|channel|>",
            "<channel|>"
        ]
        let markerSummary = markers
            .map { "\($0)=\(promptOccurrenceCount($0, in: prompt))" }
            .joined(separator: " ")
        let lineCount = prompt.split(separator: "\n", omittingEmptySubsequences: false).count
        let sectionHashes = promptSectionFingerprints(prompt)
        let diagnostic = "[PromptDiag] label=\(label) chars=\(prompt.count) lines=\(lineCount) " +
            "sha=\(promptSHA256(prompt)) \(markerSummary) sections=\(sectionHashes)"
        lastTurnPromptDiagnostics.append(diagnostic)
        log(diagnostic)
    }

    private func promptSHA256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func promptOccurrenceCount(_ needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private func promptSectionFingerprints(_ prompt: String) -> String {
        let parts = prompt.components(separatedBy: "<|turn>")
            .dropFirst()
            .prefix(8)
        let sections = parts.enumerated().map { index, rawPart in
            let role = rawPart.prefix { !$0.isNewline }
            let body = rawPart.dropFirst(role.count)
            let digest = promptSHA256(String(body))
            return "\(index):\(role):\(body.count):\(digest.prefix(10))"
        }
        return sections.joined(separator: ",")
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
        let enableThinkingForTextAnswer =
            effectiveEnableThinking && !shouldUseFullAgentPrompt && !shouldUsePlanner
        let lightHistory = shouldUsePlanner ? [] : priorHistory
        let lightPrompt = PromptBuilder.buildLightweightTextPrompt(
            userMessage: normalizedText,
            history: lightHistory,
            systemPrompt: config.systemPrompt,
            enableThinking: enableThinkingForTextAnswer,
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
            enableThinking: enableThinkingForTextAnswer,
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
                enableThinking: enableThinkingForTextAnswer
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

    /// Runs a short internal LLM probe without letting its temporary sampling
    /// settings leak into the persistent chat session.
    ///
    /// LiteRT opens a KV session with the current `maxOutputTokens`. Any probe
    /// that temporarily lowers that value must restore the normal settings
    /// before resetting/reopening KV, otherwise the next real assistant answer
    /// inherits the probe's tiny output cap.
    func runIsolatedInferenceProbe(
        prompt: String,
        maxOutputTokens: Int,
        label: String,
        onToken: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> String? {
        let snapshot = InferenceSamplingSnapshot(
            topK: inference.samplingTopK,
            topP: inference.samplingTopP,
            temperature: inference.samplingTemperature,
            maxOutputTokens: inference.maxOutputTokens
        )

        inference.samplingTopK = 1
        inference.samplingTopP = 1.0
        inference.samplingTemperature = 0
        inference.maxOutputTokens = min(snapshot.maxOutputTokens, maxOutputTokens)

        let raw = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            inference.generate(
                prompt: prompt,
                onToken: onToken,
                onComplete: { result in
                    switch result {
                    case .success(let text):
                        continuation.resume(returning: text)
                    case .failure(let error):
                        log("[\(label)] probe failed: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                    }
                }
            )
        }

        inference.samplingTopK = snapshot.topK
        inference.samplingTopP = snapshot.topP
        inference.samplingTemperature = snapshot.temperature
        inference.maxOutputTokens = snapshot.maxOutputTokens
        await inference.resetKVSession()

        return raw
    }

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
