import CoreImage
import Foundation

// MARK: - Process Input
//
// 核心推理入口: processInput 处理用户输入 (文本/图像/音频),
// 通过 prompt pipeline 构建完整 prompt 后调用 inference 流式生成。
// 包含: 输入规范化, image follow-up 路由, skill 匹配,
// prompt 构建, 上下文预算裁剪, 多模态/文本/planner 三条路径。

extension AgentEngine {

    func processInput(
        _ text: String,
        images: [PlatformImage] = [],
        audio: AudioCaptureSnapshot? = nil,
        replayImageAttachments: [ChatImageAttachment]? = nil,
        attachReplayImagesToMessage: Bool = true
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = trimmed
        let inputAttachments = images.compactMap(ChatImageAttachment.init(image:))
        let displayAttachments = replayImageAttachments != nil && !attachReplayImagesToMessage
            ? inputAttachments
            : (replayImageAttachments ?? inputAttachments)
        var promptAttachments = replayImageAttachments ?? inputAttachments
        let audioClips = audio.flatMap(ChatAudioAttachment.init(snapshot:)).map { [$0] } ?? []
        let audioInput = audio.map(AudioInput.from(snapshot:))
        let normalizedText: String
        if trimmed.isEmpty, !promptAttachments.isEmpty {
            normalizedText = PromptLocale.current.describeImagePromptFallback
        } else if audio != nil {
            // 有音频就无脑前缀 anchor — E2B/E4B 小模型会把 "这是什么？" 之类短 prompt
            // 当成问它自己, 给出 Gemma 自我介绍模板. 空 text 补一个默认意图作为填充,
            // 不再分两个音频分支。偶尔出现的 "关于这段音频：请转写音频" 式轻微冗余可
            // 接受, 胜过维护一套硬编 anchor 词表。
            let intent = trimmed.isEmpty ? PromptLocale.current.transcribeAudioIntentFallback : trimmed
            normalizedText = String(format: PromptLocale.current.audioContextFormat, intent)
        } else {
            normalizedText = trimmed
        }
        guard !isProcessing else { return }
        guard !normalizedText.isEmpty || !promptAttachments.isEmpty || audioInput != nil else { return }
        isProcessing = true
        beginGenerationTracking()

        let currentUserMessage = ChatMessage(
            role: .user,
            content: displayText,
            images: displayAttachments,
            audios: audioClips
        )
        messages.append(currentUserMessage)

        var requiresMultimodal = !promptAttachments.isEmpty || audioInput != nil
        var imageFollowUpBridgeSummary: String?
        var forceImageFollowUpTextPrompt = false
        let pendingImageFollowUpContext = !requiresMultimodal ? latestActiveImageFollowUpContext() : nil
        var earlyAssistantPlaceholderIndex: Int?
        if pendingImageFollowUpContext != nil {
            messages.append(ChatMessage(role: .assistant, content: "▍"))
            earlyAssistantPlaceholderIndex = messages.count - 1
        }
        if !requiresMultimodal,
           let recentImageContext = pendingImageFollowUpContext {
            let followUpRoute = await classifyImageFollowUpRoute(
                assistantSummary: recentImageContext.assistantSummary,
                userQuestion: normalizedText
            )
            switch followUpRoute {
            case .reMultimodal:
                promptAttachments = recentImageContext.attachments
                requiresMultimodal = true
                log("[ImageFollowUp] route=re_multimodal")
            case .imageText:
                imageFollowUpBridgeSummary = recentImageContext.assistantSummary
                forceImageFollowUpTextPrompt = true
                log("[ImageFollowUp] route=image_text")
            case .normalText:
                log("[ImageFollowUp] route=normal_text")
            }
            consumeActiveImageFollowUpContext()
        }

        applySamplingConfig()

        let matchedSkillIdsForTurn = requiresMultimodal ? [] : matchedSkillIds(for: normalizedText)
        // 暴露给 CLI harness (ScenarioRunner) 做断言. iOS UI 不读, 0 行为影响.
        self.lastTurnMatchedSkillIds = matchedSkillIdsForTurn
        // T2 (2026-04-17): 把 Planner 入口从 matched>=2 降到 matched>=1.
        //
        // 动机: Router 的 substring trigger 命中存在大量边界 fail (e.g. 用户说
        // "评审会"但 trigger 是"会议", 用户说"查王总电话"但 trigger 是"查电话"),
        // 漏掉一个 skill → planner 没被触发 → 多 skill 任务退化成单 skill agent 路径,
        // T2c-revert (2026-04-17): 恢复 matched>=2 门槛.
        //
        // T2c 把门槛从 >=2 改成 >=1, 让 Selection LLM 每轮都跑.
        // 真机验证: Selection 每次 ~1400 tok 全量 prefill (KV hit 4-6%),
        // E4B 稳态 headroom ~1000-1200 MB, 多轮必崩 (jetsam).
        // 且 Selection 实际表现: matched=1 返回同一个 skill (白跑),
        // matched=2 返回子集 (比 Router 更差). 收益 < 0, 风险 = jetsam.
        //
        // 回到 >=2: 单 skill 直接 agent 路径, 不进 Planner, 不跑 Selection.
        let shouldUsePlanner = !requiresMultimodal && matchedSkillIdsForTurn.count >= 2
        let shouldUseFullAgentPrompt =
            !requiresMultimodal
            && shouldUseToolingPrompt(for: normalizedText)
        let activeSkillInfos: [SkillInfo]
        if shouldUseFullAgentPrompt {
            if matchedSkillIdsForTurn.isEmpty {
                activeSkillInfos = enabledSkillInfos
            } else {
                let selectedIds = Set(matchedSkillIdsForTurn)
                let matchedInfos = enabledSkillInfos.filter { selectedIds.contains($0.name) }
                activeSkillInfos = matchedInfos.isEmpty ? enabledSkillInfos : matchedInfos
            }
        } else {
            activeSkillInfos = []
        }
        let policy = catalog.runtimePolicy(for: catalog.selectedModel.id)
        let headroomMB = Double(MemoryStats.headroomMB)
        let historyDepth = requiresMultimodal ? 0 : policy.safeHistoryDepth(headroomMB: headroomMB)
        let plannerHistoryDepth = shouldUsePlanner ? 0 : historyDepth
        let promptImages = promptImages(historyDepth: historyDepth, currentImages: promptAttachments)

        let routedPath = Self.decideRoute(
            requiresMultimodal: requiresMultimodal,
            shouldUsePlanner: shouldUsePlanner,
            shouldUseFullAgentPrompt: shouldUseFullAgentPrompt
        )
        PCLog.turn(
            route: routedPath,
            skillCount: matchedSkillIdsForTurn.count,
            multimodal: requiresMultimodal,
            inputChars: text.count,
            historyDepth: historyDepth,
            headroomMB: MemoryStats.headroomMB
        )

        // Tag 这条 assistant placeholder 的 skillName, 让 sticky routing 在
        // 下一轮追问时能识别上下文 (即使本轮 LLM 没调 tool 只是澄清).
        //
        // 只对 type: device 的 skill 打 tag — content skill (如 translate)
        // 是一问一答的纯变换, 它的 assistant reply 代表"已完成", 不应该让
        // 下一轮闲聊被 sticky 粘回去翻译。框架在这里按 skill metadata 决定,
        // 不硬编具体 skill 名, 也不感知模型。
        let stickyEligibleSkillID: String? = {
            guard let id = matchedSkillIdsForTurn.first,
                  let def = skillRegistry.getDefinition(id) else { return nil }
            return def.metadata.type == .device ? id : nil
        }()

        if requiresMultimodal {
            let msgIndex: Int
            if let existingIndex = earlyAssistantPlaceholderIndex,
               messages.indices.contains(existingIndex) {
                msgIndex = existingIndex
            } else {
                messages.append(ChatMessage(role: .assistant, content: "▍", skillName: stickyEligibleSkillID))
                msgIndex = messages.count - 1
            }
            // Pure-vision path 默认返回空 system prompt (见 PromptBuilder.multimodalSystemPrompt),
            // 空字符串时跳过 .system(...) 注入, 让 Gemma 4 只看 image + user text,
            // 避免任何 system 框架把小模型带进"请提供图片"漂移.
            let systemPrompt = PromptBuilder.multimodalSystemPrompt(
                hasImages: !promptImages.isEmpty,
                hasAudio: audioInput != nil,
                enableThinking: config.enableThinking
            )
            let multimodalPlan = makePromptPlan(
                prompt: systemPrompt.isEmpty ? normalizedText : systemPrompt + "\n" + normalizedText,
                shape: .multimodal,
                history: messages,
                historyDepth: 0
            )
            await prepareSessionGroupTransitionIfNeeded(for: multimodalPlan)
            var multimodalBuffer = ""

            markStreamingStarted()
            inference.generateMultimodal(
                images: promptImages,
                audios: audioInput.map { [$0] } ?? [],
                prompt: normalizedText,
                systemPrompt: systemPrompt
            ) { [weak self] token in
                guard let self = self,
                      self.messages.indices.contains(msgIndex) else { return }
                multimodalBuffer += token
                let cleaned = self.cleanOutputStreaming(multimodalBuffer)
                self.messages[msgIndex].update(content: (cleaned.isEmpty ? "" : cleaned) + "▍")
            } onComplete: { [weak self] result in
                guard let self = self else { return }
                guard self.messages.indices.contains(msgIndex) else {
                    self.finishTurn()
                    return
                }
                switch result {
                case .success(let fullText):
                    #if DEBUG
                    log("[Agent] 1st raw: \(fullText.prefix(300))")
                    #endif
                    let cleaned = self.cleanOutput(fullText)
                    self.messages[msgIndex].update(
                        content: cleaned.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : cleaned
                    )
                    self.recordRecentImageFollowUpContext(
                        attachments: promptAttachments,
                        assistantSummary: cleaned.isEmpty ? fullText : cleaned
                    )
                    self.recordCompletedObservation(plan: multimodalPlan)
                    self.finishTurn()
                case .failure(let error):
                    log("[Agent] multimodal failed: \(error.localizedDescription)")
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    self.recordCompletedObservation(
                        plan: multimodalPlan,
                        tokenCapHit: self.classifyTokenCapHit(error),
                        memoryFloorHit: self.classifyMemoryFloorHit(error)
                    )
                    self.finishTurn(error: error.localizedDescription)
                }
            }
            return
        }

        // Router 确定性匹配到的 skill: 预加载 tool 调用 schema + 工具白名单,
        // 让模型在 round 1 就看到 schema, 跳过 load_skill 往返。对小模型
        // (E2B/E4B) 效果显著 — 避免它们在"要不要 load_skill"这种主观判断上翻车。
        //
        // Path 1-B (2026-04-17): memory-aware degradation.
        //   - 内存富余 (HARNESS Mac, 真机第一轮): 用完整 SKILL body, 保留所有
        //     行为细则 (追问逻辑, 跨轮合并, 多 tool 内部路由).
        //   - 内存吃紧 (真机第 2/3 轮起, headroom < 1500 MB): 退化到 compactSchema,
        //     ~200 chars/SKILL, 牺牲行为细节换 prefill 内存峰值, 避免 jetsam.
        //
        // 不是规则, 是 memory-pressure-aware degradation —— 跟 jetsam 共生的
        // 工程实践. 阈值 1500 MB 是经验值 (E4B 单次 prefill ~700MB 峰值 + safety).
        let useCompactSchema = MemoryStats.headroomMB < 1500
        if useCompactSchema {
            log("[Agent] preload compact schema (headroom=\(MemoryStats.headroomMB) MB < 1500)")
        }
        let turnRequiresTimeAnchor = requiresTimeAnchor(forSkillIds: matchedSkillIdsForTurn)
        let includeImageHistoryMarkers =
            HotfixFeatureFlags.useHotfixPromptPipeline
            && HotfixFeatureFlags.enableImageFollowUpRegrounding
        let preloadedSkills: [PromptBuilder.PreloadedSkill] = matchedSkillIdsForTurn.compactMap { id in
            guard let body = skillRegistry.loadBody(skillId: id),
                  let def = skillRegistry.getDefinition(id) else { return nil }
            let registered = registeredTools(for: id)
            let toolTuples = registered.map { (name: $0.name, description: $0.description, parameters: $0.parameters, requiredParameters: $0.requiredParameters) }
            let compact = PromptBuilder.PreloadedSkill.makeCompactSchema(
                skillName: def.metadata.name,
                tools: toolTuples
            )
            // 当 headroom 充裕, 把 body 同时塞进 compactSchema 字段, prompt 用的就是 body
            // (零行为变化). 当 headroom 紧, compactSchema 是真紧凑版本, prompt 用紧凑.
            return PromptBuilder.PreloadedSkill(
                id: id,
                displayName: def.metadata.name,
                body: body,
                allowedTools: def.metadata.allowedTools,
                compactSchema: useCompactSchema ? compact : body
            )
        }

        // T2 (2026-04-17): 当 matched>=1, planner 和 agent 路径同时可能跑.
        // - Planner 入参用 LIGHT prompt (它内部只取 system block, 大 agent prompt
        //   会让 plan JSON 翻车 — E4B 在 3.6K char 输入下截断).
        // - 落回单 skill streaming 用 agent prompt (含 preloaded SKILL body, 能调 tool).
        let basePriorHistory = Array(messages.dropLast().suffix(historyDepth))
        var promptBundle: (
            lightPrompt: String,
            agentPrompt: String?,
            plannerInputPrompt: String,
            streamingPrompt: String,
            canUseDelta: Bool,
            streamingPlanningHistory: [ChatMessage]
        )
        if forceImageFollowUpTextPrompt, let imageFollowUpBridgeSummary {
            let imageFollowUpTextPrompt = PromptBuilder.buildImageFollowUpTextPrompt(
                userMessage: normalizedText,
                assistantSummary: imageFollowUpBridgeSummary,
                systemPrompt: config.systemPrompt,
                enableThinking: config.enableThinking
            )
            promptBundle = (
                lightPrompt: imageFollowUpTextPrompt,
                agentPrompt: nil,
                plannerInputPrompt: imageFollowUpTextPrompt,
                streamingPrompt: imageFollowUpTextPrompt,
                canUseDelta: false,
                streamingPlanningHistory: []
            )
        } else {
            promptBundle = buildTextPromptBundle(
                priorHistory: basePriorHistory,
                normalizedText: normalizedText,
                shouldUsePlanner: shouldUsePlanner,
                shouldUseFullAgentPrompt: shouldUseFullAgentPrompt,
                includeTimeAnchor: turnRequiresTimeAnchor,
                includeImageHistoryMarkers: includeImageHistoryMarkers,
                imageFollowUpBridgeSummary: imageFollowUpBridgeSummary,
                activeSkillInfos: activeSkillInfos,
                matchedSkillIdsForTurn: matchedSkillIdsForTurn,
                preloadedSkills: preloadedSkills,
                currentUserMessage: currentUserMessage
            )
        }
        let textPromptShape = promptShape(
            requiresMultimodal: false,
            shouldUseFullAgentPrompt: shouldUseFullAgentPrompt,
            canUseDelta: promptBundle.canUseDelta
        )
        var textPromptPlan = makePromptPlan(
            prompt: promptBundle.streamingPrompt,
            shape: textPromptShape,
            history: promptBundle.streamingPlanningHistory,
            historyDepth: promptBundle.streamingPlanningHistory.count
        )
        if HotfixFeatureFlags.useHotfixPromptPipeline
            && HotfixFeatureFlags.enablePreflightBudget
            && !shouldUsePlanner
            && !promptBundle.canUseDelta {
            var trimmedPriorHistory = basePriorHistory
            while exceedsSafeContextBudget(textPromptPlan.budgetDecision) {
                guard HotfixFeatureFlags.enableHistoryTrim,
                      let nextTrimmedHistory = ConversationMemoryPolicy.nextTrimmedPriorHistory(
                        from: trimmedPriorHistory
                      ) else {
                    let hardRejectMessage = PromptLocale.current.hardRejectContextTooLong
                    if let existingIndex = earlyAssistantPlaceholderIndex,
                       messages.indices.contains(existingIndex) {
                        messages[existingIndex].update(role: .system, content: hardRejectMessage)
                    } else {
                        messages.append(ChatMessage(role: .system, content: hardRejectMessage))
                    }
                    recordCompletedObservation(
                        plan: textPromptPlan,
                        advancePromptPipelineState: false,
                        preflightHardReject: true
                    )
                    finishTurn()
                    return
                }

                trimmedPriorHistory = nextTrimmedHistory
                if forceImageFollowUpTextPrompt, let imageFollowUpBridgeSummary {
                    let imageFollowUpTextPrompt = PromptBuilder.buildImageFollowUpTextPrompt(
                        userMessage: normalizedText,
                        assistantSummary: imageFollowUpBridgeSummary,
                        systemPrompt: config.systemPrompt,
                        enableThinking: config.enableThinking
                    )
                    promptBundle = (
                        lightPrompt: imageFollowUpTextPrompt,
                        agentPrompt: nil,
                        plannerInputPrompt: imageFollowUpTextPrompt,
                        streamingPrompt: imageFollowUpTextPrompt,
                        canUseDelta: false,
                        streamingPlanningHistory: []
                    )
                } else {
                    promptBundle = buildTextPromptBundle(
                        priorHistory: trimmedPriorHistory,
                        normalizedText: normalizedText,
                        shouldUsePlanner: shouldUsePlanner,
                        shouldUseFullAgentPrompt: shouldUseFullAgentPrompt,
                        includeTimeAnchor: turnRequiresTimeAnchor,
                        includeImageHistoryMarkers: includeImageHistoryMarkers,
                        imageFollowUpBridgeSummary: imageFollowUpBridgeSummary,
                        activeSkillInfos: activeSkillInfos,
                        matchedSkillIdsForTurn: matchedSkillIdsForTurn,
                        preloadedSkills: preloadedSkills,
                        currentUserMessage: currentUserMessage
                    )
                }
                textPromptPlan = makePromptPlan(
                    prompt: promptBundle.streamingPrompt,
                    shape: textPromptShape,
                    history: promptBundle.streamingPlanningHistory,
                    historyDepth: promptBundle.streamingPlanningHistory.count
                )
            }
        }
        let agentPrompt = promptBundle.agentPrompt
        let lightPrompt = promptBundle.lightPrompt
        let plannerInputPrompt = promptBundle.plannerInputPrompt
        let streamingPrompt = promptBundle.streamingPrompt
        let canUseDelta = promptBundle.canUseDelta
        if canUseDelta {
            log("[Agent] KV cache delta mode: \(streamingPrompt.count) chars (vs full \(lightPrompt.count) chars)")
        }
        await prepareSessionGroupTransitionIfNeeded(for: textPromptPlan)
        #if DEBUG
        log("[Agent] text prompt mode=\(shouldUseFullAgentPrompt ? "agent" : "light"), planner-input-chars=\(plannerInputPrompt.count), streaming-chars=\(streamingPrompt.count), skills=\(activeSkillInfos.count)")
        #endif

        let msgIndex: Int
        if let existingIndex = earlyAssistantPlaceholderIndex,
           messages.indices.contains(existingIndex) {
            msgIndex = existingIndex
        } else {
            messages.append(ChatMessage(role: .assistant, content: "▍", skillName: stickyEligibleSkillID))
            msgIndex = messages.count - 1
        }

        if shouldUsePlanner {
            log("[Agent] planner path triggered revision=\(plannerRevision)")
            let plannerHandled = await executePlannedSkillChainIfPossible(
                prompt: plannerInputPrompt,
                userQuestion: normalizedText,
                images: promptImages
            )

            if plannerHandled {
                if messages.indices.contains(msgIndex),
                   messages[msgIndex].role == .assistant,
                   messages[msgIndex].content == "▍" {
                    messages.remove(at: msgIndex)
                }
                return
            }

            // T2 (2026-04-17): planner 未处理 (Selection LLM 判定真单 skill) →
            // 不显示错误, 沉默地落回单 skill agent 路径 (placeholder ▍ 还在,
            // 下面 streaming 代码会填充).
            log("[Agent] planner not handled, falling back to single-skill agent path")
        }

        var detectedToolCall = false
        var buffer = ""
        var bufferFlushed = false

        markStreamingStarted()
        inference.generate(
            prompt: streamingPrompt,
            onToken: { [weak self] token in
                guard let self = self,
                      self.messages.indices.contains(msgIndex) else { return }

                if detectedToolCall {
                    buffer += token
                    return
                }

                buffer += token

                if buffer.contains("<tool_call>") {
                    detectedToolCall = true
                    return
                }

                if forceImageFollowUpTextPrompt {
                    return
                }

                if !bufferFlushed {
                    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return }
                    if "<tool_call>".hasPrefix(trimmed) { return }
                    bufferFlushed = true
                    self.messages[msgIndex].update(content: self.cleanOutputStreaming(buffer))
                    return
                }

                let cleaned = self.cleanOutputStreaming(buffer)
                if !cleaned.isEmpty {
                self.messages[msgIndex].update(content: cleaned)
                }
            },
            onComplete: { [weak self] result in
                guard let self = self else { return }
                guard self.messages.indices.contains(msgIndex) else {
                    self.finishTurn()
                    return
                }
                switch result {
                case .success(let fullText):
                    #if DEBUG
                    log("[Agent] 1st raw: \(fullText.prefix(300))")
                    #endif

                    if self.parseToolCall(fullText) != nil {
                        self.messages[msgIndex].update(content: "")
                        self.recordCompletedObservation(plan: textPromptPlan)
                        // Tool chain continues the turn — txn stays .streaming,
                        // finishTurn() will be called when the chain completes.
                        Task {
                            await self.executeToolChain(
                                prompt: streamingPrompt,
                                fullText: fullText,
                                userQuestion: normalizedText,
                                images: promptImages
                            )
                        }
                        return
                    } else {
                        let cleaned = self.cleanOutput(fullText)
                        self.recordCompletedObservation(plan: textPromptPlan)
                        if forceImageFollowUpTextPrompt,
                           let imageFollowUpBridgeSummary,
                           !cleaned.isEmpty {
                            Task { [weak self] in
                                guard let self else { return }
                                let repaired = await self.streamImageFollowUpStableReply(
                                    cleanedDraft: cleaned,
                                    assistantSummary: imageFollowUpBridgeSummary,
                                    userQuestion: normalizedText,
                                    msgIndex: msgIndex
                                )
                                if self.messages.indices.contains(msgIndex) {
                                    self.messages[msgIndex].update(
                                        content: repaired.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : repaired
                                    )
                                }
                                self.finishTurn()
                            }
                            return
                        }
                        self.messages[msgIndex].update(
                            content: cleaned.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : cleaned
                        )
                        self.finishTurn()
                    }
                case .failure(let error):
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    self.recordCompletedObservation(
                        plan: textPromptPlan,
                        tokenCapHit: self.classifyTokenCapHit(error),
                        memoryFloorHit: self.classifyMemoryFloorHit(error)
                    )
                    self.finishTurn(error: error.localizedDescription)
                }
            }
        )
    }


    // MARK: - Skill 结果后的后续推理（支持多轮工具链）

    func streamLLM(prompt: String, images: [CIImage]) async -> String? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            inference.generate(
                prompt: prompt,
                onToken: { _ in },
                onComplete: { result in
                    switch result {
                    case .success(let text):
                        log("[Agent] LLM raw: \(text.prefix(300))")
                        continuation.resume(returning: text)
                    case .failure(let error):
                        log("[Agent] LLM failed: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                    }
                }
            )
        }
    }

    func streamLLM(prompt: String, msgIndex: Int, images: [CIImage]) async -> String? {
        var buffer = ""
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var toolCallDetected = false
            var bufferFlushed = false
            inference.generate(
                prompt: prompt,
                onToken: { [weak self] token in
                    guard let self = self,
                          self.messages.indices.contains(msgIndex) else { return }
                    buffer += token

                if toolCallDetected { return }
                if buffer.contains("<tool_call>") {
                    toolCallDetected = true
                    if bufferFlushed && self.messages[msgIndex].role == .assistant {
                        self.messages[msgIndex].update(content: "")
                    }
                    return
                }

                if !bufferFlushed {
                    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return }
                    if "<tool_call>".hasPrefix(trimmed) { return }
                    bufferFlushed = true
                }

                let cleaned = self.cleanOutputStreaming(buffer)
                if !cleaned.isEmpty && self.messages[msgIndex].role == .assistant {
                    self.messages[msgIndex].update(content: cleaned)
                }
            },
            onComplete: { [weak self] result in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                switch result {
                case .success(let text):
                    log("[Agent] LLM raw: \(text.prefix(300))")
                    continuation.resume(returning: text)
                case .failure(let error):
                    if self.messages.indices.contains(msgIndex) {
                        self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    }
                    continuation.resume(returning: nil)
                }
            }
            )
        }
    }


    // MARK: - Generation Tracking (Phase 4)

    /// Begin generation transaction tracking at the start of a user turn.
    /// Creates a coordinator transaction if the runtime is ready.
    /// Gracefully no-ops if coordinator is not in ready state (migration path).
    func beginGenerationTracking() {
        guard coordinator.sessionState.canGenerate else { return }
        _ = coordinator.beginGeneration()
        // Don't call txn.begin() yet — that happens when inference actually starts streaming.
    }

    /// Signal that the inference stream has started for the current transaction.
    /// Call immediately before `inference.generate()` or `inference.generateMultimodal()`.
    func markStreamingStarted() {
        coordinator.currentTransaction?.begin()
    }

    /// Finish the current generation turn.
    ///
    /// Commits or terminates the active transaction based on its current state,
    /// then clears `isProcessing`. Safe to call even if no transaction is active
    /// (graceful no-op for the migration period).
    ///
    /// - Parameter error: If non-nil, the turn failed and the transaction is
    ///   terminated with an error reason. If nil, the turn succeeded normally.
    ///   If the transaction is in `.cancelling` state (user pressed stop),
    ///   it's terminated as cancelled regardless of this parameter.
    func finishTurn(error: String? = nil) {
        if let txn = coordinator.currentTransaction, !txn.isTerminal {
            if txn.state == .cancelling {
                // Cancel flow in progress — mark terminated so coordinator's
                // async cancel can proceed with KV reset.
                txn.markTerminated(reason: .userCancelled)
            } else if let error {
                txn.markTerminated(reason: .error(error))
                coordinator.completeGeneration()
            } else {
                // Normal completion. If txn is still .created (e.g. planner
                // path where streamLLM() ran but markStreamingStarted() was
                // never called explicitly), transition through begin→commit.
                if txn.state == .created {
                    txn.begin()
                }
                txn.commit()
                coordinator.completeGeneration()
            }
        }
        isProcessing = false
    }

    // MARK: - Helpers

    func promptImages(
        historyDepth: Int,
        currentImages: [ChatImageAttachment]
    ) -> [CIImage] {
        _ = historyDepth
        return Array(currentImages.prefix(1).compactMap(\.ciImage))
    }
}
