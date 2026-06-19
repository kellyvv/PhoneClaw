import Foundation

extension LiveModeEngine {
    // MARK: - MAIN Agent Bridge

    func processMainAgentTextTurn(
        transcript: String,
        generation gen: UInt64,
        initialMetrics: LiveTurnMetrics
    ) async {
        var metrics = initialMetrics
        metrics.llmStartedAt = CFAbsoluteTimeGetCurrent()
        await liveActivity.update(
            phase: "processing",
            headline: "正在执行",
            detail: transcript
        )
        backgroundContinuation.update(phase: "processing", detail: transcript)

        let output = await runMainAgentTextTurn(transcript: transcript, generation: gen)
        metrics.llmFirstTokenAt = metrics.llmStartedAt
        metrics.llmCompletedAt = CFAbsoluteTimeGetCurrent()
        metrics.tokenCount = max(metrics.tokenCount, 1)
        currentTurnMetrics = nil

        guard turnPhase == .processing, turnGeneration == gen else {
            metrics.interrupted = true
            print(metrics.summary())
            return
        }

        let displayText = output.displayText
        lastReply = displayText
        lastSkillInfo = output
        liveProgressHeadline = nil
        liveCaption = displayText
        inputLevel = 0

        if !transcript.isEmpty && !displayText.isEmpty {
            appendLiveHistory(role: .user, content: transcript)
            appendLiveHistory(role: .assistant, content: displayText)
        }

        await liveActivity.update(
            phase: "result",
            headline: output.displayName,
            detail: displayText,
            skillID: output.skillID,
            skillName: output.displayName,
            toolName: output.toolName,
            success: output.success,
            alertTitle: output.success ? "Skill 已完成" : "Skill 未完成",
            alertBody: displayText
        )
        backgroundContinuation.update(phase: "result", detail: displayText)
        print("[LiveAgent] info output skill=\(output.skillID) tool=\(output.toolName ?? "none") success=\(output.success)")
        print(metrics.summary())

        lastAssistantPlaybackEndTime = CFAbsoluteTimeGetCurrent()
        turnPhase = .listening
        state = .listening
        statusMessage = liveStrings.listeningPrompt
        scheduleLiveActivityListeningRefresh(afterResultGeneration: gen)
        print("[Live] 👂 Listening...")
    }

    @MainActor
    func runMainAgentTextTurn(transcript: String, generation gen: UInt64) async -> LiveSkillInfoOutput {
        guard let agentEngine else {
            return LiveSkillInfoOutput(
                skillID: "agent",
                displayName: "PhoneClaw",
                toolName: nil,
                success: false,
                summary: tr("主 Agent 不可用。", "The main agent is unavailable."),
                detail: ""
            )
        }

        let startIndex = agentEngine.messages.count
        var lastProgressKey: String?
        let receivedProgress = liveAgentReceivedProgressSnapshot()
        await publishMainAgentProgress(receivedProgress, generation: gen)
        lastProgressKey = receivedProgress.key

        await agentEngine.processInput(transcript)

        let deadline = Date().addingTimeInterval(mainAgentTurnTimeout)
        while Date() < deadline,
              agentEngine.isProcessing || agentEngine.isModelGenerating {
            let safeStart = min(startIndex, agentEngine.messages.count)
            let newMessages = Array(agentEngine.messages.dropFirst(safeStart))
            let progress = liveAgentProgressSnapshot(from: newMessages, agentEngine: agentEngine)
            if progress.key != lastProgressKey {
                await publishMainAgentProgress(progress, generation: gen)
                lastProgressKey = progress.key
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let timedOut = agentEngine.isProcessing || agentEngine.isModelGenerating
        let safeStart = min(startIndex, agentEngine.messages.count)
        let newMessages = Array(agentEngine.messages.dropFirst(safeStart))
        if timedOut {
            print("[LiveAgent] main Agent turn still processing after \(Int(mainAgentTurnTimeout))s")
            return liveTimedOutInfoOutput(
                newMessages,
                agentEngine: agentEngine,
                summary: tr(
                    "还在处理中，可以回到主界面查看结果。",
                    "Still processing. You can return to the main chat to see the result."
                )
            )
        }

        return liveInfoOutputFromMainAgentMessages(
            newMessages,
            agentEngine: agentEngine,
            fallbackSummary: tr("已完成。", "Done."),
            timedOut: false
        )
    }

    private func liveAgentReceivedProgressSnapshot() -> LiveAgentProgressSnapshot {
        LiveAgentProgressSnapshot(
            key: "received",
            phase: "understanding",
            headline: "已收到指令",
            detail: "已收到指令，请稍等。",
            skillID: nil,
            skillName: nil,
            toolName: nil
        )
    }

    @MainActor
    private func liveAgentProgressSnapshot(
        from messages: [ChatMessage],
        agentEngine: AgentEngine
    ) -> LiveAgentProgressSnapshot {
        if let assistantMessage = messages.reversed().first(where: { message in
            guard message.role == .assistant else { return false }
            let cleaned = cleanMainAgentVisibleText(message.content)
            return !cleaned.isEmpty && cleaned != "▍"
        }) {
            return LiveAgentProgressSnapshot(
                key: "answering-\(assistantMessage.id.uuidString)",
                phase: "summarizing",
                headline: "正在生成结果",
                detail: "已经整理好信息，正在生成回答。",
                skillID: nil,
                skillName: nil,
                toolName: nil
            )
        }

        if let toolMessage = messages.reversed().first(where: {
            $0.role == .skillResult && $0.skillResultKind == .toolExecution
        }), let toolName = toolMessage.skillName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !toolName.isEmpty {
            return liveAgentToolResultProgressSnapshot(toolName: toolName, agentEngine: agentEngine)
        }

        if let executingMessage = messages.reversed().first(where: {
            $0.role == .system && $0.content.hasPrefix("executing:")
        }) {
            let toolName = String(executingMessage.content.dropFirst("executing:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return liveAgentExecutingProgressSnapshot(
                toolName: toolName,
                displayName: executingMessage.skillName,
                agentEngine: agentEngine
            )
        }

        if let identifiedMessage = messages.reversed().first(where: {
            $0.role == .system && ($0.content == "identified" || $0.content == "loaded")
        }), let displayName = identifiedMessage.skillName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return LiveAgentProgressSnapshot(
                key: "identified-\(displayName)",
                phase: "understanding",
                headline: "已识别 Skill",
                detail: "已识别为 \(displayName)，正在准备执行。",
                skillID: agentEngine.findSkillId(for: displayName),
                skillName: displayName,
                toolName: nil
            )
        }

        return liveAgentReceivedProgressSnapshot()
    }

    @MainActor
    private func liveAgentExecutingProgressSnapshot(
        toolName: String,
        displayName: String?,
        agentEngine: AgentEngine
    ) -> LiveAgentProgressSnapshot {
        let skillID = agentEngine.findSkillId(for: toolName)
        let skillName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayName
            : agentEngine.findDisplayName(for: toolName)

        switch toolName {
        case "web-search":
            return LiveAgentProgressSnapshot(
                key: "executing-web-search",
                phase: "searching",
                headline: "正在搜索",
                detail: "正在搜索相关信息，请稍等。",
                skillID: skillID,
                skillName: skillName,
                toolName: toolName
            )
        case "web-fetch":
            return LiveAgentProgressSnapshot(
                key: "executing-web-fetch",
                phase: "searching",
                headline: "正在读取来源",
                detail: "正在打开相关网页并提取内容。",
                skillID: skillID,
                skillName: skillName,
                toolName: toolName
            )
        default:
            return LiveAgentProgressSnapshot(
                key: "executing-\(toolName)",
                phase: "executing",
                headline: "正在执行",
                detail: "正在执行 \(skillName ?? toolName)。",
                skillID: skillID,
                skillName: skillName,
                toolName: toolName
            )
        }
    }

    @MainActor
    private func liveAgentToolResultProgressSnapshot(
        toolName: String,
        agentEngine: AgentEngine
    ) -> LiveAgentProgressSnapshot {
        let skillID = agentEngine.findSkillId(for: toolName)
        let skillName = agentEngine.findDisplayName(for: toolName)

        switch toolName {
        case "web-search":
            return LiveAgentProgressSnapshot(
                key: "result-web-search",
                phase: "summarizing",
                headline: "正在总结",
                detail: "已检索到相关信息，正在整理答案。",
                skillID: skillID,
                skillName: skillName,
                toolName: toolName
            )
        case "web-fetch":
            return LiveAgentProgressSnapshot(
                key: "result-web-fetch",
                phase: "summarizing",
                headline: "正在总结",
                detail: "已读取相关来源，正在整理答案。",
                skillID: skillID,
                skillName: skillName,
                toolName: toolName
            )
        default:
            return LiveAgentProgressSnapshot(
                key: "result-\(toolName)",
                phase: "summarizing",
                headline: "正在整理",
                detail: "\(skillName) 已返回结果，正在整理。",
                skillID: skillID,
                skillName: skillName,
                toolName: toolName
            )
        }
    }

    @MainActor
    private func publishMainAgentProgress(
        _ progress: LiveAgentProgressSnapshot,
        generation gen: UInt64
    ) async {
        guard turnPhase == .processing, turnGeneration == gen else { return }
        liveProgressHeadline = progress.headline
        lastSkillInfo = nil
        lastReply = progress.detail
        await liveActivity.update(
            phase: progress.phase,
            headline: progress.headline,
            detail: progress.detail,
            skillID: progress.skillID,
            skillName: progress.skillName,
            toolName: progress.toolName
        )
        backgroundContinuation.update(phase: progress.phase, detail: progress.detail)
        print("[LiveAgent] progress phase=\(progress.phase) headline=\(progress.headline) detail=\(progress.detail)")
    }

    @MainActor
    private func liveTimedOutInfoOutput(
        _ messages: [ChatMessage],
        agentEngine: AgentEngine,
        summary: String
    ) -> LiveSkillInfoOutput {
        let toolMessage = messages.reversed().first {
            $0.role == .skillResult && $0.skillResultKind == .toolExecution
        }

        if let toolMessage,
           let toolName = toolMessage.skillName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !toolName.isEmpty {
            return LiveSkillInfoOutput(
                skillID: agentEngine.findSkillId(for: toolName) ?? toolName,
                displayName: agentEngine.findDisplayName(for: toolName),
                toolName: toolName,
                success: false,
                summary: summary,
                detail: ""
            )
        }

        return LiveSkillInfoOutput(
            skillID: "agent",
            displayName: "PhoneClaw",
            toolName: nil,
            success: false,
            summary: summary,
            detail: ""
        )
    }

    @MainActor
    private func liveInfoOutputFromMainAgentMessages(
        _ messages: [ChatMessage],
        agentEngine: AgentEngine,
        fallbackSummary: String,
        timedOut: Bool
    ) -> LiveSkillInfoOutput {
        let assistantText = messages.reversed().compactMap { message -> String? in
            guard message.role == .assistant else { return nil }
            let cleaned = cleanMainAgentVisibleText(message.content)
            return cleaned.isEmpty ? nil : cleaned
        }.first

        let toolMessage = messages.reversed().first {
            $0.role == .skillResult && $0.skillResultKind == .toolExecution
        }

        if let toolMessage,
           let toolName = toolMessage.skillName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !toolName.isEmpty {
            let canonical = canonicalToolResult(toolName: toolName, toolResult: toolMessage.content)
            let skillID = agentEngine.findSkillId(for: toolName) ?? toolName
            let displayName = agentEngine.findDisplayName(for: toolName)
            let summary = assistantText ?? canonical.summary
            return LiveSkillInfoOutput(
                skillID: skillID,
                displayName: displayName,
                toolName: toolName,
                success: timedOut ? false : canonical.success,
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackSummary : summary,
                detail: canonical.detail
            )
        }

        return LiveSkillInfoOutput(
            skillID: "agent",
            displayName: "PhoneClaw",
            toolName: nil,
            success: !timedOut,
            summary: assistantText ?? fallbackSummary,
            detail: ""
        )
    }

    private func cleanMainAgentVisibleText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "▍", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
